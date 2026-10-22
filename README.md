# Clairvoyance

A REFramework Lua mod for Dragon's Dogma 2 that puts more of the world on your
map and in your view.

## Features

1. Side quests appear on the map and minimap as color-coded icons with hover
   labels, grouped by state: startable, in progress, completed, unavailable,
   locked, and quest-item.
2. Overhead indicators mark the quest giver for startable quests and the current
   objective NPC for quests in progress.
3. In-progress quests track their current objective, including the items a quest
   still needs.
4. Startable quests that are gated behind another quest say what they wait on in
   their map hover.
5. A Quest tree panel in the settings window groups every known side quest by
   region.
6. A world tracker marks chests, treasure, Seeker's Tokens, Golden Trove Beetles,
   monsters, quest-item sellers and shops. Shops list their stock in the World
   panel.
7. A map search box filters markers by name and also matches shop stock and
   monster drops.
8. Marker selection follows the map cursor.

## Requirements

1. Dragon's Dogma 2 (Steam).
2. REFramework.

## Install

1. Download `Clairvoyance.zip` from the GitHub Releases page.
2. Add the zip in Fluffy Mod Manager, or extract the `reframework` folder from it
   into the game folder by hand, merging with the existing `reframework` folder.
3. Start the game.

The release zip includes the generated places file the world tracker reads
(`reframework/data/Clairvoyance_places.json`).

## Settings

Open the REFramework menu and expand Clairvoyance. Icon
types, colors, the quest tree, the world tracker categories and the map search
box are all there. Settings are saved to `reframework/data/Clairvoyance.json`.

## Development

Offline tests run with Lua 5.4:

    powershell -NoProfile -File scripts/check.ps1 -Lua <path to lua.exe> -Luac <path to luac.exe>

The check script syntax-checks every Lua file, runs the offline tests, and runs
the packaging tests. `scripts/build-zip.ps1` builds the release zips and
`scripts/deploy.ps1` copies the mod into a game install for testing.

The optional pak reader in `tools/` regenerates the places file from the game's
archives. It needs your own key file, `tools/pak_key.local.txt`, which is not
included in this repository.

## Places file

`data/Clairvoyance_places.json` is generated from the game files with
`tools/extract_world.py` and your own key file. It is regenerated and committed
after a game patch. CI and the release zip use the committed copy.

## Releasing

Releases are automatic. Every push to `master` is read by `scripts/next_version.py`,
which looks at the commits since the latest `v<major>.<minor>.<patch>` tag and
bumps the version from their Conventional Commit types:

| Commits since the last tag | Bump |
| --- | --- |
| a `BREAKING CHANGE:` footer, or `type!:` / `type(scope)!:` | major |
| otherwise any `feat` | minor |
| otherwise any `fix` or `perf` | patch |
| only `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `style`, `revert` | no release |

When a bump is due, CI builds the zip, creates the release `v<version>` on the
Releases page with generated notes, and attaches the zip. Do not tag by hand.
Pull requests fail CI if a commit subject is not `type(scope)?!?: description`.

`modinfo.ini` keeps `version=1.0.0` as a placeholder; the release zip carries the
real version.

## License

MIT. See `LICENSE`.
