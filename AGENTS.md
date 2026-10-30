# Clairvoyance

Clairvoyance is a REFramework Lua mod for Dragon's Dogma 2 (main file
`reframework/autorun/Clairvoyance.lua`, modules in `reframework/autorun/Clairvoyance/`): color-coded map and minimap icons +
hover labels for side quests by lifecycle state, and in-world overhead
indicators above spawned quest NPCs — the giver for startable quests, the
current objective NPC for in-progress ones; startable quests gated
behind another quest's progress say so in their map hover; a
collapsible Quest tree panel in the settings window groups every
known side quest by region; map, minimap and overhead markers for the
items an in-progress quest still needs; a world tracker (v10) for chests,
treasure, Seeker's Tokens, Golden Trove Beetles, monsters and quest-item
sellers, placed from a generated places file; a map search box (v11) that
filters those markers by name and adds shop stock and monster drops; a
Shops toggle (v12) puts every shop on the map as "<npc> (shop)" and lists
each shop's stock and quest-item lines in the World panel; matching icons
(v13) draw the game's own map icon pictures, tinted with the category color,
on the full map, the minimap and above heads through the D2DX plugin
(Dragon's Dogma 2 mod 1261), and fall back to the game glyphs without it.
Spec: `docs/SPEC.md`.

`docs/` (SPEC.md, plans, ROADMAP.md) is a separate local git repo. It is gitignored
here and never pushed; roadmap and spec edits are committed there, not in this repo.

## Rules

1. **No personal or secret data in this repo, ever** — not in tracked files, history,
   commit metadata, or fixtures. Covered: credentials, emails, real names,
   account/machine usernames, LAN IPs, hostnames, MAC addresses, absolute paths
   containing a username, session IDs, harvested command/session history, and paths
   or names from other local projects. Scan before any first push; a deleted file is
   still in history. If found: stop and report — no silent scrubbing.
2. The Steam game path (`C:\Program Files (x86)\Steam\steamapps\common\Dragons
   Dogma 2`) contains no username and is fine to reference in scripts and docs.
3. Never create a remote or push without the operator's explicit instruction.
4. Commit messages: no backticks or `$(...)` in double-quoted shell strings; use
   `git commit -F -` fed by a single-quoted heredoc.
5. Release zips carry the places file (`Clairvoyance_places.json`), the hints file
   (`Clairvoyance_hints.json`), the quests file (`Clairvoyance_quests.json`) and the icon
   folder (`reframework/images/Clairvoyance/icons/`), never
   the extractors (`tools/`) or the pak key. The icon folder is generated from
   game files with `tools/extract_icons.py` and the user's own key, committed,
   and regenerated after a game patch; never hand-edit the pictures. The quests
   file is generated from game files with `tools/extract_quests.py` and the
   user's own key, committed, and regenerated after a game patch, like the icon
   folder. The key lives only in the
   gitignored `tools/pak_key.local.txt`; it is never printed, committed or
   zipped.
6. CI (`.github/workflows/ci.yml`) runs `check.ps1 -SkipProvenance` and builds the zip
   from the committed `data/Clairvoyance_places.json`; releases are automatic from
   Conventional Commit types on push to master (`scripts/next_version.py`), never hand-tagged.
7. Commit titles must follow Conventional Commits: `type(scope)?!?: description` with type feat, fix, perf, refactor, docs, test, build, ci, chore, style or revert.
8. README install and requirements steps may name the release page, a mod manager and the required plugins (operator ruling 2026-10-24); the no-naming rule covers code provenance, other mods' authors and hint sources, not install instructions.
9. How the work is done (game research, in-game probes in `tools/probe/`, and the spec, plan, parallel-lane build and landing process): `.claude/skills/clairvoyance-workflow/SKILL.md`. Read it before starting a ROADMAP item.
10. Before any deploy, Reset Scripts request, live correction or handoff, read
    `.claude/skills/verified-live-handoff/SKILL.md` and obey its whole-product
    acceptance gate. A provider-local pass cannot close a live regression.
