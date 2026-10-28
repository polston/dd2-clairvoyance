"""Runs a Lua probe chunk in the game through tools/probe/qnml_check.lua.
Usage: python tools/probe/run.py <chunk.lua> [timeout_s] --game <game folder>
Writes the chunk to reframework/data/qnml_cmd.txt, waits for the harness's
"CHK cmd ok=" line in re2_framework_log.txt, then prints the CHK lines the
chunk logged and any framework [error] line that mentions the mod. On TIMEOUT
(default 30 s) it prints TIMEOUT, blanks the queued chunk file so the harness
cannot run it later, and exits 1.
"""
import argparse
import os
import re
import sys
import time

# The harness prefixes its own periodic dump lines with this; a chunk's lines
# never start with it.
NOISE = "~ "
POST_SUCCESS_GRACE = 1.0
UNSAFE_METHODS = {"create_instance", "set_field", "add_ref", "release"}
SAFE_SDK_METHODS = {"find_type_definition", "get_managed_singleton"}
SECONDARY_LOADERS = {"load", "loadfile", "dofile"}
ALLOWED_REQUIRE = {"Clairvoyance.world"}
# Exact TalkEventManager reads; canTalkEventInteract takes Character, while
# the other three take TalkEventDefine.ID (verified in the local dump).
REVIEWED_METHODS = {
    "IsRelease", "ToString()", "evaluate", "evaluateHide",
    "evaluateRegisterCondition", "evaluateShow", "evaluateUpdateShow",
    "getActiveDestinations", "getCurrentTask", "getCurrentTaskConciergeData",
    "getItemNumber", "getItemShopTotalPay", "getItemStockNum",
    "getNPCCharacterData", "getProgressingQuestIds",
    "getRegisterableDestinations", "getStorageDict",
    "getHistory", "getTalkEventInitialSpeaker",
    "get_AIBlackBoardController", "get_Area", "get_Canceled",
    "get_CanceledAction", "get_CharaID", "get_CompContext", "get_Count",
    "get_CurrentTaskIndex", "get_Data", "get_DataList", "get_DeliverData",
    "get_DeliveryCheckStorage", "get_DeliveryGroupID", "get_DeliveryIsNot",
    "get_Destinations", "get_DestType", "get_DoneAction", "get_ErrorStatus",
    "get_Executed", "get_FakeShopCompleteTime", "get_FakeShopKeepedItem",
    "get_GimmickID", "get_GmContext", "get_IsAllItem", "get_IsFinish",
    "get_IsDead", "get_IsOpenedFreeBit", "get_IsRemove", "get_IsStock",
    "get_IsUnlockFreeBit", "get_Item", "get_ItemList", "get_Key",
    "get_KeyLocation", "get_LocalArea", "get_Operator", "get_Process",
    "get_QuestID", "get_SetNpc", "get_Stock", "get_TaskIndex",
    "get_Transform", "get_UniqId", "get_UniversalPosition",
    "get_Value", "getContext", "hasDeliver", "isEventPlayable",
    "isFakeShopCompleted", "isFakeShopKeeped", "isFakeShopRemainingMinute",
    "isFinish", "canTalkEventInteract",
    "isShopTalkEventAvailableForChara",
    "isTalkEventInteractDisabled",
}
REVIEWED_CAPABILITIES = {
    "reviewed_call": 1,
    "reviewed_try_call": 1,
    "reviewed_invoke": 2,
}


def _long_bracket(source, pos):
    """Return (content_start, closing token) for a Lua long bracket at pos."""
    if pos >= len(source) or source[pos] != "[":
        return None
    end = pos + 1
    while end < len(source) and source[end] == "=":
        end += 1
    if end >= len(source) or source[end] != "[":
        return None
    return end + 1, "]" + source[pos + 1:end] + "]"


def _short_string(source, pos):
    """Return a best-effort Lua short-string value and its end offset."""
    quote = source[pos]
    value = []
    simple = {
        "a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r",
        "t": "\t", "v": "\v", "\\": "\\", '"': '"', "'": "'",
    }
    pos += 1
    while pos < len(source):
        ch = source[pos]
        if ch == "\\" and pos + 1 < len(source):
            escaped = source[pos + 1]
            if escaped.isdigit():
                end = pos + 1
                while (end < len(source) and end < pos + 4 and
                       source[end].isdigit()):
                    end += 1
                code = int(source[pos + 1:end])
                value.append(chr(code) if code <= 255 else "")
                pos = end
            elif (escaped == "x" and pos + 3 < len(source) and
                  all(c in "0123456789abcdefABCDEF"
                      for c in source[pos + 2:pos + 4])):
                value.append(chr(int(source[pos + 2:pos + 4], 16)))
                pos += 4
            elif escaped == "z":
                pos += 2
                while pos < len(source) and source[pos].isspace():
                    pos += 1
            else:
                value.append(simple.get(escaped, escaped))
                pos += 2
        elif ch == quote:
            return "".join(value), pos + 1
        else:
            value.append(ch)
            pos += 1
    return "".join(value), pos


def _lua_tokens(source):
    """Tokenize enough Lua to find unsafe member access outside literals."""
    tokens = []
    pos = 0
    while pos < len(source):
        if source.startswith("--", pos):
            long = _long_bracket(source, pos + 2)
            if long:
                start, closing = long
                end = source.find(closing, start)
                pos = len(source) if end < 0 else end + len(closing)
            else:
                end = source.find("\n", pos + 2)
                pos = len(source) if end < 0 else end + 1
            continue
        ch = source[pos]
        if ch.isspace():
            pos += 1
            continue
        if ch in "'\"":
            value, pos = _short_string(source, pos)
            tokens.append(("string", value))
            continue
        long = _long_bracket(source, pos)
        if long:
            start, closing = long
            end = source.find(closing, start)
            value = source[start:] if end < 0 else source[start:end]
            if value.startswith(("\r\n", "\n\r")):
                value = value[2:]
            elif value.startswith(("\r", "\n")):
                value = value[1:]
            tokens.append(("string", value))
            pos = len(source) if end < 0 else end + len(closing)
            continue
        if ch == "_" or ch.isalpha():
            end = pos + 1
            while (end < len(source) and
                   (source[end] == "_" or source[end].isalnum())):
                end += 1
            tokens.append(source[pos:end])
            pos = end
            continue
        tokens.append(ch)
        pos += 1
    return tokens


def _receiver_token(token):
    return (token in (")", "]") or
            isinstance(token, str) and
            bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token)))


def _matching_close(tokens, start, opening, closing):
    depth = 0
    for pos in range(start, len(tokens)):
        if tokens[pos] == opening:
            depth += 1
        elif tokens[pos] == closing:
            depth -= 1
            if depth == 0:
                return pos
    return None


def _sdk_expression(tokens, start, end):
    if start > end:
        return False
    if start == end:
        return tokens[start] == "sdk"
    if (tokens[start] == "(" and
            _matching_close(tokens, start, "(", ")") == end):
        return _sdk_expression(tokens, start + 1, end - 1)
    return False


def _sdk_receiver(tokens, end):
    if end < 0:
        return False
    if tokens[end] == "sdk":
        return True
    if tokens[end] != ")":
        return False
    depth = 1
    pos = end - 1
    while pos >= 0:
        if tokens[pos] == ")":
            depth += 1
        elif tokens[pos] == "(":
            depth -= 1
            if depth == 0:
                return _sdk_expression(tokens, pos, end)
        pos -= 1
    return False


def _setter_argument(tokens, opening):
    closing = _matching_close(tokens, opening, "(", ")")
    if closing is None:
        return None
    for token in tokens[opening + 1:closing]:
        if (isinstance(token, tuple) and token[0] == "string" and
                re.match(r"^set_", token[1])):
            return token[1]
    return None


def _call_arguments(tokens, opening):
    closing = _matching_close(tokens, opening, "(", ")")
    if closing is None:
        return None
    args, start = [], opening + 1
    depths = {"(": 0, "[": 0, "{": 0}
    pairs = {")": "(", "]": "[", "}": "{"}
    for pos in range(start, closing):
        token = tokens[pos]
        if token in depths:
            depths[token] += 1
        elif token in pairs:
            depths[pairs[token]] -= 1
        elif token == "," and all(depth == 0 for depth in depths.values()):
            args.append(tokens[start:pos])
            start = pos + 1
    if start < closing:
        args.append(tokens[start:closing])
    return args


def _managed_method_argument(tokens, opening, colon):
    args = _call_arguments(tokens, opening)
    index = 0 if colon else 1
    if args is None or index >= len(args):
        return None
    arg = args[index]
    if len(arg) == 1 and isinstance(arg[0], tuple) and arg[0][0] == "string":
        return arg[0][1]
    return False


def unsafe_probe_call(source):
    tokens = _lua_tokens(source)
    # First preserve the specific diagnostics for direct unsafe calls.
    for pos, token in enumerate(tokens):
        if (token == "." and pos + 1 < len(tokens) and
                tokens[pos + 1] == "create_resource" and
                _sdk_receiver(tokens, pos - 1)):
            return "sdk.create_resource"
        if (token in (".", ":") and pos + 1 < len(tokens) and
                tokens[pos + 1] in UNSAFE_METHODS):
            return tokens[pos + 1]
        if (token in (".", ":") and pos + 2 < len(tokens) and
                tokens[pos + 1] == "call" and tokens[pos + 2] == "("):
            method = _managed_method_argument(tokens, pos + 2, token == ":")
            if method is False or method is None:
                return "dynamic managed method"
            if method in UNSAFE_METHODS or method.startswith("set_"):
                return method
            setter = _setter_argument(tokens, pos + 2)
            if setter is not None:
                return setter
            return "raw managed call"
        if (token == "[" and pos > 0 and pos + 2 < len(tokens) and
                _receiver_token(tokens[pos - 1]) and
                isinstance(tokens[pos + 1], tuple) and
                tokens[pos + 1][0] == "string" and tokens[pos + 2] == "]"):
            member = tokens[pos + 1][1]
            if _sdk_receiver(tokens, pos - 1) and member == "create_resource":
                return "sdk.create_resource"
            if member in UNSAFE_METHODS:
                return member
            if (member == "call" and pos + 3 < len(tokens) and
                    tokens[pos + 3] == "("):
                method = _managed_method_argument(tokens, pos + 3, False)
                if method is False or method is None:
                    return "dynamic managed method"
                if method in UNSAFE_METHODS or method.startswith("set_"):
                    return method
                setter = _setter_argument(tokens, pos + 3)
                if setter is not None:
                    return setter
                return "raw managed call"

    # The guard is deliberately fail-closed around capabilities that can hide
    # a later engine call. Read-only probes use direct, reviewed SDK members;
    # arbitrary code loading, SDK aliases and computed member calls do not.
    member_aliases = set()
    for pos, token in enumerate(tokens):
        if (token == "=" and pos > 0 and pos + 2 < len(tokens) and
                isinstance(tokens[pos - 1], str) and
                re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tokens[pos - 1]) and
                _receiver_token(tokens[pos + 1]) and tokens[pos + 2] == "["):
            closing = _matching_close(tokens, pos + 2, "[", "]")
            if closing is not None:
                member_aliases.add(tokens[pos - 1])
    for pos, token in enumerate(tokens):
        if token in member_aliases and pos + 1 < len(tokens) and tokens[pos + 1] == "(":
            return "indirect managed call"
        if token in REVIEWED_CAPABILITIES:
            if (pos > 0 and tokens[pos - 1] in (".", ":")) or (
                    pos + 1 >= len(tokens) or tokens[pos + 1] != "("):
                return "indirect reviewed call"
            args = _call_arguments(tokens, pos + 1)
            index = REVIEWED_CAPABILITIES[token]
            if args is None or index >= len(args):
                return "unreviewed managed method"
            method = args[index]
            if (len(method) != 1 or not isinstance(method[0], tuple) or
                    method[0][0] != "string" or method[0][1] not in REVIEWED_METHODS):
                return "unreviewed managed method"
        if token in SECONDARY_LOADERS:
            return token
        if token == "require":
            direct = (pos + 3 < len(tokens) and tokens[pos + 1] == "(" and
                      isinstance(tokens[pos + 2], tuple) and
                      tokens[pos + 2][0] == "string" and
                      tokens[pos + 2][1] in ALLOWED_REQUIRE and
                      tokens[pos + 3] == ")")
            protected = (pos >= 2 and tokens[pos - 2] == "pcall" and
                         tokens[pos - 1] == "(" and
                         pos + 2 < len(tokens) and tokens[pos + 1] == "," and
                         isinstance(tokens[pos + 2], tuple) and
                         tokens[pos + 2][0] == "string" and
                         tokens[pos + 2][1] in ALLOWED_REQUIRE)
            if not direct and not protected:
                return "require"
        if token in ("_G", "_ENV"):
            reviewed_debug = (token == "_G" and pos + 2 < len(tokens) and
                              tokens[pos + 1] == "." and
                              tokens[pos + 2] == "QNML_DEBUG")
            if not reviewed_debug:
                return "indirect global access"
        if token == "sdk":
            direct = (pos + 2 < len(tokens) and tokens[pos + 1] == "." and
                      tokens[pos + 2] in SAFE_SDK_METHODS)
            if not direct:
                if pos + 1 < len(tokens) and tokens[pos + 1] == "[":
                    return "dynamic sdk access"
                return "indirect sdk access"
        if token in (".", ":") and pos + 1 < len(tokens) and tokens[pos + 1] == "call":
            if pos + 2 >= len(tokens) or tokens[pos + 2] != "(":
                return "indirect managed call"
        if token == "[":
            closing = _matching_close(tokens, pos, "[", "]")
            if closing is None:
                return "dynamic member call"
            literal = (closing == pos + 2 and
                       isinstance(tokens[pos + 1], tuple) and
                       tokens[pos + 1][0] == "string")
            if (closing + 1 < len(tokens) and tokens[closing + 1] == "(" and
                    not literal):
                return "dynamic member call"
            if (literal and tokens[pos + 1][1] == "call" and
                    (closing + 1 >= len(tokens) or tokens[closing + 1] != "(")):
                return "indirect managed call"
    return None


def crash_evidence(text):
    low = text.lower()
    if re.search(r"exception occurred\s*:\s*[0-9a-f]+", low):
        return "engine exception"
    if "attempting to write dump" in low:
        return "crash dump write"
    return None


def crash_dump_stamp(path):
    try:
        stat = os.stat(path)
    except FileNotFoundError:
        return None
    return stat.st_size, stat.st_mtime_ns


def crash_dump_changed(before, after):
    return before != after


def command_result(text):
    matches = re.findall(r"CHK cmd ok=(true|false)\b", text)
    if not matches:
        return None
    return matches[-1] == "true"


def is_mod_error(line):
    """A framework or mod error line that mentions the mod or its files."""
    low = line.lower()
    if "[error]" in low and ("clairvoyance" in low or "qnml" in low):
        return True
    return "[clairvoyance]" in low and "error" in low


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chunk")
    ap.add_argument("timeout", nargs="?", type=float, default=30.0)
    ap.add_argument("--game", required=True)
    a = ap.parse_args()
    log = os.path.join(a.game, "re2_framework_log.txt")
    cmd = os.path.join(a.game, "reframework", "data", "qnml_cmd.txt")
    crash_dump = os.path.join(a.game, "reframework_crash.dmp")
    with open(a.chunk, encoding="utf-8") as f:
        src = f.read()
    unsafe = unsafe_probe_call(src)
    if unsafe:
        print("UNSAFE PROBE: %s" % unsafe)
        return 2
    start = os.path.getsize(log)
    dump_before = crash_dump_stamp(crash_dump)
    with open(cmd, "w", encoding="utf-8") as f:
        f.write(src)
    deadline = time.time() + a.timeout
    text, result, result_at, fatal = "", None, None, None
    while time.time() < deadline or result_at is not None:
        time.sleep(0.5)
        with open(log, "rb") as f:
            f.seek(start)
            text = f.read().decode("utf-8", "replace")
        fatal = crash_evidence(text)
        if fatal is None and crash_dump_changed(
                dump_before, crash_dump_stamp(crash_dump)):
            fatal = "crash dump changed"
        if fatal is not None:
            break
        observed = command_result(text)
        if observed is not None and result is None:
            result = observed
            if not result:
                break
            result_at = time.time()
        if result_at is not None and time.time() - result_at >= POST_SUCCESS_GRACE:
            break
    if fatal is not None:
        print("CRASH: %s" % fatal)
        with open(cmd, "w", encoding="utf-8") as f:
            f.write("")
    elif result is None:
        print("TIMEOUT")
        with open(cmd, "w", encoding="utf-8") as f:
            f.write("")
    warned = False
    for line in text.splitlines():
        if "CHK " in line:
            s = line.split("CHK ", 1)[1]
            if s.startswith("setup_icon_n") and not warned:
                warned = True
                print("WARN: the installed harness is older than tools/probe/qnml_check.lua;"
                      " copy it into the game's reframework/autorun/ and press Reset Scripts")
            if not s.startswith(NOISE):
                print(s)
        elif is_mod_error(line):
            print("LOG", line[-200:])
    return 0 if result is True and fatal is None else 1


if __name__ == "__main__":
    sys.exit(main())
