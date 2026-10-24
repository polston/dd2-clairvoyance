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
9. Matching icons: every category draws the same picture in the same color on
   the full map, the minimap and above heads. The pictures are the game's own
   map icons, tinted with the category color. Without the D2DX plugin the mod
   draws as before, with the game's icon glyphs.
10. Optional numbered icons (Hex 1 to 5) mark in-progress quests by their
    current journal step.
11. Every picture and text the mod draws can have an outline, one global
    setting with an optional override per marker category. The route line
    and the route stop pictures have their own color and size settings.
12. A searched NPC's daily route can follow the game's own walking paths
    instead of straight lines, on the full map and, optionally, in the world.
13. Chests say what kind they are in their label ("stays opened in NG+",
    "quest-gated", "trap", and so on), the map search finds them by kind, and
    each kind has its own toggle.
14. Map coordinates show beside the full map's cursor and under the minimap.
15. NPC search: the same search box finds named NPCs, lists them under "NPCs"
    with a "Show on map" button and a "Route" checkbox, and a routed NPC's day
    appears as numbered stops on the map.
16. NPC names above heads, with how they feel about you, for quest NPCs only
    or for all named NPCs.
17. In the item menu, quest-related items get a small dot on their slot, and
    the selected one is labelled with its quest above the item panel.
18. Quest hints: a Hints node in the Quest tree, closed until you open it,
    with pins on the map and in the world for the step you are on. The shipped
    hints file lists quest items only so far; its text and pins are still to
    come.

## Requirements

1. Dragon's Dogma 2 (Steam).
2. REFramework.
3. For matching icons: the D2DX plugin. Without it,
   or with "Matching icons (D2DX)" turned off, every surface keeps the game's
   own icon glyphs and the rest of the mod works the same.

## Install

1. Download `Clairvoyance.zip` from the GitHub Releases page.
2. Add the zip in Fluffy Mod Manager, or extract the `reframework` folder from it
   into the game folder by hand, merging with the existing `reframework` folder.
3. Start the game.

The release zip includes the generated places file the world tracker reads
(`reframework/data/Clairvoyance_places.json`).

## Settings

Open the REFramework menu and expand Clairvoyance. Settings are saved to
`reframework/data/Clairvoyance.json`. The panel, top to bottom: Enabled, the
search box with its results and NPC list, then these sections: Quests, World
markers, NPCs, Items, Map and minimap, Appearance, Quest tree, World, and
Status and debug.

### World markers

One checkbox per category (chests, treasure, beetles, sellers, shops, show
opened and collected, undiscovered areas) and a cap on the number of markers.
Two categories are trees with two checkboxes each. Seeker's Tokens holds "All
Seeker's Tokens" and "Finder's Token spot (first token found)": the spot where
you picked up your first Seeker's Token this playthrough, which a Sphinx riddle
asks for. It shows even when the other tokens are off. Monsters is a tree of
"Large monsters" and "Small monsters", each with its own checkbox and one
checkbox per kind seen (Cyclops, Goblin and so on), so a single kind can be
switched off. The World panel uses the same trees: the spot is listed first
under Seeker's Tokens, and Monsters splits into a Large node and a Small node,
each holding one node per kind. A chest's label ends with its kinds in brackets,
for example "Chest - Wakestone [stays opened in NG+]", and the map search
matches those words. Five checkboxes under Chests turn each kind on or off; a
chest with several kinds is hidden when any one of them is off:

1. New shard each cycle: the Wakestone Shard chests that are full again in each
   New Game Plus cycle.
2. Stays opened in NG+: the Wakestone, Wakestone Shard and Portcrystal chests
   that stay opened after a New Game Plus.
3. Quest-gated: chests that open only after a quest, or only until one ends.
   The label names the quest only if you have seen it or turned on "Reveal
   gating quest names"; otherwise it says "another quest". A chest whose quest
   is known to be over fades.
4. Trap: opening the chest spawns enemies.
5. Pawns can't open: your pawns will not open the chest.

### NPCs

"NPC names above heads" is Off, Quest NPCs or All named NPCs. Searching an NPC
by name lists it under "NPCs (N)" in the search results; its "Route" checkbox
draws that NPC's day, one routed NPC at a time.

"Route path" draws a searched NPC's route as straight lines or along the
game's walking paths ("Walking path", the default). "Show route path in the
world" draws the walking path in the world too. The path search needs a copy of
the game's walking graph, which the mod makes over a second or two in small
slices the first time a walking-path route is shown.

### Items

"Mark quest items in the item menu" puts a dot on each quest-related slot in
the item menu and labels the selected item with its quest above the item
panel. The dots and the label use the "Quest items" color from Appearance.

### Map and minimap

Minimap indicators, Matching icons (D2DX), and two coordinates toggles:
"Coordinates beside the map cursor" shows the cursor's map position as
"X 123  Z -456" on the full map, and "Coordinates under the minimap" shows your
position as "X 123  Z -456  H 78" (H is height) and fades with the minimap. The
numbers are in the same space as the search results and markers.

### Appearance

1. Outlines: on or off, color and width (1 to 4 pixels at 1080 lines; wider on
   larger displays). Outlines are drawn on pictures the mod draws through the
   D2DX plugin and on its text, not on the game's own icon glyphs.
2. Route: line color and width, stop picture size, and the stop number's color
   and size.
3. Names color.
4. Overrides: for each marker category, the route line, the names and the item
   menu, an Override checkbox with its own outline on or off, color and width.
5. Icons and colors: the icon and color of each category.

"Reset appearance to defaults" puts every category icon and color and every
appearance setting back to its default; it leaves the two NPCs route path
settings alone. The first start after the matching-icons update replaces any
icon or color you never changed with the new default; a value you changed is
kept.

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

## Icon pictures

`reframework/images/Clairvoyance/icons/` holds one white 64x64 picture per
game map icon, plus `index.json`. They are generated from the game files with
`tools/extract_icons.py` and your own key file, committed, and shipped in the
release zip. Re-run the extractor after a game patch.

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
