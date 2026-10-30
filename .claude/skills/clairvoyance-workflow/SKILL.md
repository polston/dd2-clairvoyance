---
name: clairvoyance-workflow
description: How Clairvoyance work is done - researching the game (offline game data and live in-game probes) and the spec, plan, parallel-lane build and landing process. Use before researching game behaviour, starting a ROADMAP item, writing a spec or plan, running in-game checks, or landing a branch.
---

# Clairvoyance workflow

Two halves: how we find out what the game does (research), and how a change goes
from a ROADMAP row to master (process). The rules in AGENTS.md and CLAUDE.md
always apply; this file says how the work is done.

## Part 1: Research

Every claim about the game is checked against the game, never guessed. Three
sources, in this order of preference.

### 1. Offline game data (the archive)

1. `tools/qnml_pak.py` reads the game's archive read-only. The key lives only
   in the gitignored `tools/pak_key.local.txt`. Check it with
   `python tools/key_check.py` (prints present or missing only). Never print,
   log, copy or commit the key.
2. `tools/qnml_rsz.py` decodes user-data and scene files. Field layouts come
   from `tools/layouts.json`. Regenerate it with
   `python tools/build_layouts.py --dump <game folder>/il2cpp_dump.json --enums <game folder>/Enums_Internal.hpp --out tools/layouts.json`.
   The framework writes both dump files into the game folder. They are never
   copied into the repo. `<game folder>` is the `-GameDir` default in
   `scripts/deploy.ps1` unless the operator's install differs; pass the same
   value to deploy.ps1, run.py and the extractors.
3. A type with no layout in the dump: fit it by hand against real files. Extend
   the field list until the file decodes to its last byte, then add it to
   `NATIVE_LAYOUTS` in `tools/build_layouts.py` and regenerate. That is how
   GameObject, Transform and Folder were fitted.
4. Extractors (`extract_world.py`, `extract_quests.py`, `extract_icons.py`)
   print counts only, never positions or values, and self-check. A failed
   check writes no output file. Their generated files are committed and
   regenerated after a game patch, never hand-edited. Invocations:
   1. Ad-hoc reads: `import qnml_pak, qnml_rsz, key_check`, then
      `qnml_pak.Pak(os.path.join(game, 're_chunk_000.pak'), key_check.read_key()).read('<archive path>')`,
      then `qnml_rsz.decode(data, json.load(open('tools/layouts.json')))`. The
      base archive only: the extractors refuse patch archives that hold entries.
   2. `python tools/extract_world.py --game <game folder> --out data/Clairvoyance_places.json`;
      `python tools/extract_quests.py --game <game folder> --out data/Clairvoyance_quests.json`;
      `python tools/extract_icons.py --game <game folder>` (writes
      `reframework/images/Clairvoyance/icons/`).
   3. No key yet: `python tools/key_check.py --write-from <local file holding the key literal>`.
      It pulls the `bytes.fromhex(...)` literal without printing it.
5. Before building on a data source, measure it. Count what decodes and what
   fails, and name the failures. Record the counts in the SPEC section.

### 2. Live reads in the running game

The mod exposes a debug table `QNML_DEBUG` while its Debug setting is on. It
offers `state`, `world`, `focus`, `route`, `set`, `jump`, `expand` and others;
see the `_G.QNML_DEBUG = {` block in `reframework/autorun/Clairvoyance.lua`.
Reach internals with `debug.getupvalue` on those functions (the framework's
Lua exposes the `debug` library; checked in game 2026-10-25), for example
the world tracker as the `wt` upvalue of `D.state`.

1. Install the dev harness: copy `tools/probe/qnml_check.lua` into the
   game's `reframework/autorun/`, again whenever that file changes (run.py
   warns when the installed copy is older). The operator then presses Reset
   Scripts. It
   is never in the release zip.
   1. `QNML_DEBUG` exists only while the mod's Debug setting is on. If the log
      shows `CHK QNML_DEBUG nil true`, Debug is off. Turn it on in the mod's
      settings window (driven with the input tools in section 3), then check
      for `CHK ready`.
2. The harness polls every 30 frames (about twice a second at 60 fps),
   starting 120 frames after a script load. Its first poll runs
   `reframework/data/qnml_boot.txt` once, which is for probes that must run
   straight after a load. After that it runs whatever is in
   `reframework/data/qnml_cmd.txt` and blanks the file. In the chunk, `D` is
   `QNML_DEBUG`, `L(s)` logs `CHK <s>`, and `dump()` logs the state summary.
   The chunk's return value comes back in the `CHK cmd ok=true <value>` line.
   Every 5 s the harness logs setup_icon_n, map_ctor_n, the tracked quest and
   the `D.state().lines` and `.jumps`, each line prefixed `CHK ~ `.
3. Write the probe chunk to a file and run
   `python tools/probe/run.py <chunk.lua> [timeout_s] --game <game folder>`.
   It prints the chunk's `CHK` lines, the `cmd ok=<true|false> <return value or error>`
   line, and any framework `[error]` line that mentions the mod. On TIMEOUT it
   clears the queued chunk and exits 1.
   Probe chunks may only read engine-owned objects and invoke managed methods
   through the harness's literal allowlisted `reviewed_call`,
   `reviewed_try_call` and `reviewed_invoke` capabilities. The runner and
   installed harness reject raw/dynamic/aliased managed dispatch, managed-object
   construction, field mutation, reference retention/release, resource
   creation, unreviewed secondary loading and indirect SDK/global access before `load`,
   for both boot and command chunks. Never bypass that guard; an unavailable
   boundary stays unknown. After a success line, the runner waits briefly and
   fails if the framework reports an engine exception or writes/changes a crash
   dump.
4. Reset Scripts, after installing the harness and after each
   `scripts/deploy.ps1`, is the only step that needs the operator. Everything
   else (map, camera, menus, settings) you drive yourself.
5. A probe that changes settings restores them before it ends, including on
   failure. Leave the game as you found it. Never edit the save file.
   `D.set(key, v)` writes the settings file `reframework/data/Clairvoyance.json`
   at once, so a change persists across restarts. Keys: the named cases in
   the `set = function(key, v)` block (enabled, journal_spoilers, debug,
   search_text, matching_icons, step_icons, overhead_names,
   inventory_quest_marks, world_max_markers), the toggles in
   `settings_util.WORLD_BOOLS` and `settings_util.WORLD_KIND_BOOLS`, and any
   other key `settings_util.set_key` accepts (focus, route, style, colour
   and icon keys). Read the old value
   from the settings first and restore it inside a pcall-guarded finally.
6. One probe runs every variant and logs each result. Never ask the operator
   to repeat a test.

### Live regression handoff gate

1. A provider-specific positive or negative is never whole-product acceptance.
   After every deployment and Reset Scripts, run `just accept-routes`. It checks
   the complete focused-objective projection across every provider.
2. A focused need with zero total targets, or published targets with zero total
   objective routes, is a regression gate failure. Do not reinterpret it as an
   expected negative for the provider currently being changed.
3. Add the smallest RED regression before fixing any live failure. Keep that
   regression plus this live gate green before asking the operator to evaluate
   the game.
4. Reset Scripts is an intermediate event. After the operator reports the reset,
   immediately run the remaining probes and continue the active plan; never use
   the reset response as a session boundary.
5. When operator feedback exposes a repeatable process failure, add or strengthen
   a durable test, command, workflow rule or skill in the same correction. A
   promise about future behavior is not remediation.

### 3. Screens and input

1. `powershell -File tools/probe/focus.ps1` brings the game window to the front.
2. `powershell -File tools/probe/shot.ps1 <out.png>` captures the game window.
   Look at the picture yourself; never ask the operator to observe it.
3. `powershell -File tools/probe/input.ps1 click X Y | wheel X Y DELTA | key VK [SCAN] | drag X1 Y1 X2 Y2`
   sends input in screen coordinates. A point at pixel (px,py) in the shot is
   screen (X+px, Y+py), using the X,Y that shot.ps1 prints (`saved WxH at X,Y`).
   Escape is sent as `key 27 1` (virtual key 27, scan code 1) to close the map;
   without the scan code the game ignores it (checked in game).
4. World rounds are held while the full map is open or a pause menu is up.
   Close both before timing world rounds.

### 4. Measuring

1. Take medians over many samples (frames or rounds), with max beside them.
2. Compare with the feature on and off at the same place in the game.
3. Timing fields live in `D.state()` (`tick_median`, `world_path_ms`, `draw`,
   `names`). Log them from the chunk with `L(...)`; the periodic dump does not
   include them.
4. Record the numbers in the SPEC section with what was measured and where. A
   number whose subject changed after it was taken is re-taken, or stamped
   with the commit it was true at.

### Hint text research

`tools/hints_fetch.py` reads `tools/hint_sources.local.txt` (gitignored, one
`<qid> <url>` per line) and saves each page as `reference/hints/<qid>/<n>.html`
and `.txt`. Both live in the main checkout. Run the fetch before writing any
hint text, or the gate's hints check fails. Hints are paraphrased in our own words.
`tools/hints_check.py` fails on any 8-word run shared with a source. Sources
are never named in tracked text, comments included; `scripts/provenance.ps1`
enforces this with the gitignored `scripts/provenance.local.txt` pattern list.

## Part 2: Process

The spec, plans and ROADMAP live in `docs/`, a separate private git repo that
is never pushed. Commit edits there, not here.

Worktrees: `docs/`, `reference/`, `.superpowers/` and the `*.local.txt` files
exist only in the main checkout. Find it with
`git rev-parse --path-format=absolute --git-common-dir`; its parent directory
is the main checkout. Ledgers, spec and roadmap edits go there, never into a
lane worktree.

### Order of work

1. `docs/ROADMAP.md` is the execution order. Start the top open item; do not
   ask which one.
2. Each implementation effort follows these steps in order:
   1. Write the spec: a numbered section in `docs/SPEC.md`.
   2. Review the spec.
   3. Fold the findings.
   4. Write the plan in `docs/superpowers/plans/`, with the writing-plans skill.
   5. Review the plan.
   6. Fold the findings.
   7. Get operator approval.
   8. Build.
3. Reviews: at most two rounds per document. Round 1 runs every lens at once:
   1. claims against the machine (run every checkable claim);
   2. invariants against AGENTS.md and the SPEC;
   3. gaps (what an implementer must guess);
   4. one blind adversarial reviewer told only "break this against the code".

   Round 2 only confirms the folds. Wording and count fixes need no round.
4. Operator wording in the SPEC is quoted verbatim. Operator rulings are
   dated.

### Building

1. Plans name parallel lanes: file-disjoint groups of tasks with their
   dependencies marked. Each lane gets its own worktree and branch forked from
   the feature branch (`git worktree add ../clv-<lane> -b feat/<lane> feat/<feature>`), one
   implementer per lane. Lanes merge back into the feature branch as their
   reviews close.
2. Execution uses subagent-driven development, with explicit models:
   1. Implementers on the cheaper model.
   2. Reviewers on the stronger model.
   3. Design and folding stay with the main session.
3. Each plan keeps a ledger in `.superpowers/sdd/<plan>/progress.md`
   (gitignored), with briefs, reports and review packages beside it. Every
   decision the plan does not settle is recorded there as
   `Ruling: <what> - <why> - <cost if wrong>`, and work continues.
4. The gate is `powershell -NoProfile -File scripts/check.ps1` (add
   `-Lua <path> -Luac <path>` only when they are not on PATH). It must end `check.ps1: all OK`. Its `locals:` lines give the chunk-level
   local budget of `Clairvoyance.lua` and `adapter.lua`. New state goes in
   fields (`wt`, `icons`), not new chunk-level locals. `scripts/deploy.ps1`
   runs this gate before touching the installed mod and refuses deployment on
   failure; pass it the same `-Lua` and `-Luac` paths.
5. The repo stores Lua files with LF. This machine's `core.autocrlf=true`
   checks them out as CRLF. Whatever tool edits a file, run `git diff --stat`
   afterwards: it must show only the lines you meant to change, never a
   whole-file rewrite.
6. After the lanes merge: deploy, check in game (Part 1), and fold what the
   game shows into the SPEC before calling the feature done.

### Landing a feature branch

Do these steps in order, without asking between them:
1. Final whole-branch review. One fix round, then one scoped re-review.
2. `/simplify` over the branch diff. Apply the fixes that change no
   behaviour. Then run the gate, then a scoped review of the cleanup commits.
3. Docs sweep with the finding-what-a-change-made-false method, over README,
   AGENTS.md, CLAUDE.md, the code comments and `docs/`.
4. Move ledger items meant to outlive the work (deferred findings, parked
   rulings) into ROADMAP rows. Each row states its fix.
5. Merge locally into master (`git merge --no-ff -F <file>`). Run the gate on
   master. Deploy.
6. Remove the lane worktrees, branches and the plan's ledger folder.
7. Push only when the operator says so. Before the push, scan every commit
   message, every tree, the full patches, tags and author metadata for
   personal data and named sources. A push to master makes CI publish the
   next version from the Conventional Commit types (`scripts/next_version.py`).

### Commits

1. Conventional Commits titles.
2. Write the message with `git commit -F -` fed by a single-quoted heredoc.
   Use no backticks in it.
3. A merge message goes in a file and is passed with `-F <file>`.
