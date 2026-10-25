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
   from `tools/layouts.json`, which `tools/build_layouts.py` cuts from the SDK
   dump kept in `reference/` (gitignored).
3. A type with no layout in the dump: fit it by hand against real files. Extend
   the field list until the file decodes to its last byte, then add it to
   `NATIVE_LAYOUTS` in `tools/build_layouts.py` and regenerate. That is how
   GameObject, Transform and Folder were fitted.
4. Extractors (`extract_world.py`, `extract_quests.py`, `extract_icons.py`)
   print counts only, never positions or values, and self-check. A failed
   check writes no output file. Their generated files are committed and
   regenerated after a game patch, never hand-edited.
5. Before building on a data source, measure it. Count what decodes and what
   fails, and name the failures. Record the counts in the SPEC section.

### 2. Live reads in the running game

The mod exposes a debug table `QNML_DEBUG` while its Debug setting is on. It
offers `state`, `world`, `focus`, `route`, `set`, `jump`, `expand` and others;
see the `_G.QNML_DEBUG = {` block in `reframework/autorun/Clairvoyance.lua`.
Reach internals with `debug.getupvalue` on those functions.

1. Install the dev harness once. Copy `tools/probe/qnml_check.lua` into the
   game's `reframework/autorun/`. It is never in the release zip.
2. The harness runs any Lua chunk written to `reframework/data/qnml_cmd.txt`
   about twice a second. In that chunk, `D` is `QNML_DEBUG` and `L(s)` logs a
   `CHK` line. Every 5 s it also logs `D.state()`.
3. Write the probe chunk to a file and run
   `python tools/probe/run.py <chunk.lua> [timeout_s] --game <game folder>`. It prints the `CHK`
   lines and any mod error from `re2_framework_log.txt`.
4. After `scripts/deploy.ps1` the operator presses Reset Scripts. That is the
   only step that needs them. Everything else (map, camera, menus, settings)
   you drive yourself.
5. A probe that changes settings restores them before it ends, including on
   failure. Leave the game as you found it. Never edit the save file.
6. One probe runs every variant and logs each result. Never ask the operator
   to repeat a test.

### 3. Screens and input

1. `powershell -File tools/probe/focus.ps1` brings the game window to the front.
2. `powershell -File tools/probe/shot.ps1 <out.png>` captures the game window.
   Look at the picture yourself; never ask the operator to observe it.
3. `powershell -File tools/probe/input.ps1 click X Y | wheel X Y DELTA | key VK [SCAN] | drag X1 Y1 X2 Y2`
   sends input in screen coordinates. Escape needs its scan code (`key 27 1`)
   to close the map.
4. World rounds are held while the full map is open. Close the map before
   timing world rounds.

### 4. Measuring

1. Take medians over many samples (frames or rounds), with max beside them.
2. Compare with the feature on and off at the same place in the game.
3. Record the numbers in the SPEC section with what was measured and where. A
   number whose subject changed after it was taken is re-taken, or stamped
   with the commit it was true at.

### Hint text research

`tools/hints_fetch.py` downloads guide pages listed in a local sources file
into `reference/hints/` (gitignored). Hints are paraphrased in our own words.
`tools/hints_check.py` fails on any 8-word run shared with a source. Sources
are never named in tracked text, comments included; `scripts/provenance.ps1`
enforces this with the gitignored `scripts/provenance.local.txt` pattern list.

## Part 2: Process

The spec, plans and ROADMAP live in `docs/`, a separate private git repo that
is never pushed. Commit edits there, not here.

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
   the feature branch (`git worktree add ../clv-<lane> -b feat/<lane>`), one
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
4. The gate is
   `powershell -NoProfile -File scripts/check.ps1 -Lua <lua.exe> -Luac <luac.exe>`.
   It must end `check.ps1: all OK`. Its `locals:` lines give the chunk-level
   local budget of `Clairvoyance.lua` and `adapter.lua`. New state goes in
   fields (`wt`, `icons`), not new chunk-level locals.
5. Lua files keep CRLF line endings. Edit with byte-level reads and writes,
   never `sed -i`.
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
