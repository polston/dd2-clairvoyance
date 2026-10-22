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
each shop's stock and quest-item lines in the World panel. Spec: `docs/SPEC.md`.

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
5. Release zips carry the places file (`Clairvoyance_places.json`), never
   the extractor (`tools/`) or the pak key. The key lives only in the
   gitignored `tools/pak_key.local.txt`; it is never printed, committed or
   zipped.
6. CI (`.github/workflows/ci.yml`) runs `check.ps1 -SkipProvenance` and builds the zip
   from the committed `data/Clairvoyance_places.json`; release = bump `version=` in
   `modinfo.ini`, commit, tag `v<version>`, push the tag (the operator pushes).
