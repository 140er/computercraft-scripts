# Schematic spec (route A)

This is the visual system for every server-only screen. It replaces the Big Tiles spec
([BIG-TILES-SPEC.md](BIG-TILES-SPEC.md)), which stays for the screens not ported yet.

Screens are drawn in plain text cells, with no filled tiles, block digits or sextant terrain.
Structure comes from the CC font's own thin strokes. The background is dark and almost
everything is grey or white; colour marks state only.

The design record is the generator in [schematic/](schematic/) and the fixtures it writes to
`tests/ui/fixtures/`. The route A prototype screens that are not ported yet live in
`schematic/prototype.py`.

## 1. Type

- One size: the CC font at text scale 0.5 (`far` displays use 1).
- Role names and section titles are capitals (`STATUS`, `TURTLES`). Values are white `0`,
  labels are muted `8`.
- Numbers sit right-aligned at the end of a dotted leader, as in a timetable:
  `ore ·········· 214`.
- No taglines, helper text or secondary labels. If a screen needs one, change the layout.

## 2. Structure

- **Header (row 1):** role name at column 2, then the tabs, then a dim hairline `-` (`c`) out
  to the state word or time at the right edge.
- **Section:** a muted title, a hairline, and an optional muted count at the right end.
- **Columns** are split by a dim `|` rule (`c`) that stops with the content.
- No boxes, except the map callout and the alert frame.
- Labels sit next to the thing they name, so no screen has a legend.

## 3. Palette

The frame header carries the palette. Slot meanings are those of Big Tiles, except that slot `3`
is steel and the no-server palette uses slot `2` for its coral bar.

| Slot | RGB | Use | On `f` | On `7` |
| --- | --- | --- | --- | --- |
| `f` | `0B111C` | background | | |
| `7` | `18223A` | panel: chips, selected row | | |
| `c` | `28344D` | hairlines, leader dots, rules | 1.5 | 1.3 |
| `8` | `7886A3` | labels, muted values, idle | 5.2 | 4.3 |
| `3` | `9DB0D2` | steel: dug passages, tick fill | 8.6 | 7.2 |
| `0` | `E6EAF2` | values and names | 15.7 | 13.1 |
| `d` | `3DDC84` | working, ok | 10.6 | 8.9 |
| `1` | `FFC24B` | waiting, low | 11.8 | 9.8 |
| `e` | `FF6B5E` | lost, broken, the alert | 6.8 | 5.7 |
| `b` | `5AB0FF` | held: lane and cells ahead of a turtle | 8.2 | 6.8 |
| `9` | `2DD4BF` | server, shaft, primary action, active toggle | 10.2 | 8.5 |
| `a` | `B69CFF` | spare | 8.3 | 6.9 |
| `2` | `E57FD8` | spare (coral `FF6B5E` in the no-server palette) | 7.5 | 6.3 |
| `4` `5` `6` | `DEDE6C` `7FCC19` `F2B2CC` | spare | | |

Contrast is the WCAG ratio against the background slot. `so-ui.lua` exports the table as
`U.palette` and the no-server grey ramp as `U.stale` (every colour slot `46526C`, `0` `6A7690`,
`c` `222B3E`, `2` coral).

### Contrast rule for coloured glyphs

- On `f` and `7`, a glyph may be `0`, `3`, `8`, `9`, `d`, `1`, `e`, `b`, `a` or `2`. Each is at
  least 4.3:1; only `8` drops under 4.5:1, and only on `7`, where it marks a control that does
  nothing in the current state.
- `c` draws structure only: `-` `|` `+` `·` `¦` and spaces. Never letters, digits or markers.
- On a coloured background (`d` `1` `e` `b` `9` `a`) the glyph is `f`.
- On `c` the glyph is `0` or `3`.

`tests/ui/s0.lua` checks this rule on every cell of every route A fixture and frame.

## 4. Colour

- Green `d`: working or ok. Amber `1`: waiting or low. Coral `e`: lost, broken, or the alert.
  Blue `b`: held. Teal `9`: the server and shaft, primary actions, the active toggle.
- In lists and logs the glyph or a `•` mark carries the colour; the text stays white. A state
  word that is not ok (`wait lane`, `lost`) takes its colour; ok states stay white.
- `U.tone(word)` gives a state word's colour. Words are matched at word starts:
  `lost broken block error fail missing expire refuse` are coral, `wait hold range recover stale
  low full` amber, `idle stop done off` and empty or `-` muted, anything else green.
  `U.mark(line)` colours a log line's mark: coral, amber, or muted `8`.

## 5. Progress

Tick rows with an explicit fraction. `|||||||··· 7/10` for branches, `♠♠♠♠♠♠♠♠♣♣ 9/12` for the
farm, and the disk drawn the same way with its percentage or size. A row of `n` cells fills
`floor(part * n / whole + 0.5)` cells, and at least one when part is above zero. The remainder is
muted `·`.

## 6. Controls

- One-row chips on the panel colour `7`, padded by one space or centred in a fixed width.
- Kinds: `plain` (`0` on `7`), `primary` (`9` on `7`), `stop` (`e` on `7`), `muted` (`8` on `7`,
  a button that does nothing now, such as START while running), `on` (`f` on `9`, an active
  toggle such as FIT), `off` (`8` on `f`, an inactive chip in a row of choices).
- Screen-wide actions sit on the last row, view controls on the first, inline chips (steppers,
  categories, order sizes) next to the value they change.

## 7. Navigation inside a role

- Tabs in the header row: `MINING overview setup`, the pocket's `FLEET JOBS SHOP PAIR`. The
  active tab is `0` on `7`; others are muted. Tab ids are `tab:<name in lower case>`.
- Selection is the panel colour behind a list row. On the map a selected marker is inverted and
  gets a callout.
- A role never changes from a tap (R1); pages and tabs inside it do.

## 8. Large line digits

Only for numbers read across a room: the pair code and the unassigned display id. Thin
seven-segment digits drawn with `- | +`, default 4 cells wide, 5 rows tall, 2 cells apart.
`-` draws the middle stroke alone, so a code not issued yet reads `------`.

## 9. Glyphs

| Glyph | Byte | Kit name | Use |
| --- | --- | --- | --- |
| `▲ ► ▼ ◄` | 30 16 31 17 | `U.arrow(facing)` | turtles by facing (0 north) |
| `•` | 7 | `g.bullet` | chests, list marks, a turtle without a facing |
| `×` | 215 | `g.cross` | broken chest |
| `♠ ♣` | 6 5 | `g.spade`, `g.club` | ready and growing trees |
| `º` | 186 | `g.shaft` | shaft |
| `·` | 183 | `g.dot` | planned work, leader dots, separators |
| `¦` | 166 | `g.gap` | planned shaft |
| `- \| +` | | | passages, rules, line digits |
| `@` | | | server |
| `↑` | 24 | `"\24N"` in `so-mod-map.lua` | the map compass, with `N` |

Bytes 16-31 pass `so-proto` serialisation, compact rows and the client's `term.blit` unchanged
(`tests/ui/s0.lua`). Monitor sync in game is still to be checked in Gate B.

## 10. The map

`so-mod-map.lua` draws it; `schematic/mapdraw.py` (cells, markers, labels, callouts) and
`schematic/mapscreen.py` (sizes, controls, roster) are its twins and write the `map-*` fixtures from
the `view` lines in `tests/ui/map-scene.txt`.

- **Orientation:** north is up at every size and for every mine facing: x grows to the right, z
  downwards. The map never turns; only the scales change. A compass `↑N` (byte 24, then `N`, muted
  `8`) sits at the right end of the top row, outside the map area, so markers, labels and callouts
  never reach it. Because the axes keep their direction, the arrow stays true when `sx` and `sz`
  differ; only distances stretch.
- **Cells:** a text cell covers `sx` by `sz` blocks. Its glyph comes from the block adjacencies
  inside it: mostly along x gives `-`, mostly along z `|`, both `+`. Dug cells are solid and steel
  `3`; planned cells are dotted (`·`, `¦`) and muted; held cells are blue. Dug pieces off the mine
  geometry of six blocks or fewer draw as one steel `·`. The cell pass reads seven blocks past the
  view, so a dig cut by the edge keeps its size.
- **Scale:** the free axis steps 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64; the axis the branches step
  along (z for a north or south mine, x for east or west) steps 1, 2, 4, ... 64 and its view edge
  aligns so every branch lands on the first block row (or column) of its cell. FIT picks the
  smallest scales that hold the mine, farm, drops, server and turtles at the level, with eight
  spare columns for labels. `-` and `+` step both axes one rung and keep the picked block in place;
  the arrows move a third of the view.
- **Markers:** turtles in their state colour, `º` shaft, `@` server, `•` and `×` chests, trees inside
  a hairline farm outline (clipped at the view edge).
- **Labels:** placed greedily, turtles first, then drops and the server, then the shaft and the farm
  count. Right, left and the diagonals are tried; a label may not touch another marker or label, and
  covering a passage costs more than empty ground. Ok turtles show only their id, others id and the
  first word of their state. From `sx` 3 only ids remain and plain chests lose their labels; a broken
  chest is always labelled.
- **Branch numbers:** muted, on the side of the spine away from the branches when free, or at the
  screen edge when the spine is off screen. Shown while the branch axis is at 2 or less.
- **Taps:** a tapped marker is inverted and gets a callout box in its colour with a connector:
  a turtle shows id, state, age, position, fuel, ore and lease; a drop its id, kind, position and
  state; the server and shaft their position (the shaft its lane holder). A tap on empty ground
  inverts the cell and shows its position and `dug`, `planned` or `held #id`. The box fits its
  text (14 cells or more) and sits below or above the marker, toward the middle first, wherever it
  hides the fewest markers. Tap the marker or the box again to close it.
- **Sizes:**

| Size | Kind | Layout |
| --- | --- | --- |
| 80x30 and up (100x38, 164x81) | wall | every control in row 1, the map from row 3, a `TURTLES` roster strip at the bottom (33-cell columns, two rows apart, `+N more` past four lines) |
| 52 wide and up (57x24) | room | every control in row 1: `MAP`, `FIT`, `- +`, `◄ ▲ ▼ ►`, then `▼ ALL ▲ ↑N` at the right; the map below |
| 25 to 51 wide (26x20, 39x19, 29x12) | pocket | `MAP`, `FIT`, `▼ ALL ▲ ↑N` on top; `◄ ▲ ▼ ► - +` on the last row |
| smaller (15x10) | tiny | `▼ ALL ▲ ↑N` on top; the arrows, then `- FIT +` on the last two rows |

- **Frames:** a frame over 15000 bytes draws one zoom step out, at most four times.
- **Exports:** `map.thumb(C, x, y, w, h)` draws the compass on row `y` and the fitted map under it,
  top-aligned (the status wall). `map.crop(C, x, y, w, h, focus)` draws one block per cell around
  `focus` (`{x, y, z, id?, drop?}`), shifted along x so the scene fills it, at the mine level when
  `focus.y` is at or under it, else ALL,
  with turtle `id` or drop `drop` inverted and no callout (the alert). Both return true when they drew
  and never wait.

## 11. Frame size

Frames stay under the 16 KB wire limit. `D.compact` lets a blank cell join the previous run
whatever its fg, so planned dots and labels do not split runs at every space. The 164x81 map
fixture (`schematic-map-XL`, the full map screen) is 13.5 KB with that rule and 15.9 KB without it;
the map packs its own runs the same way and steps out when a frame would pass 15000 bytes. Every row with content costs about
140 bytes or more, so the biggest walls cap their rows (section 13).

## 12. Kit

`so-ui.lua` and `schematic/kit.py` have the same calls; change both together.

| Lua (canvas `C`) | Python | Draws |
| --- | --- | --- |
| `C.bar(name, tabs?, active?, right?, rfg?, y?)` | `bar(cv, ...)` | header row |
| `C.section(x, y, w, title, right?, rfg?)` | `section` | section title and hairline |
| `C.rule(x1, y, x2, fg?)` | `rule` | hairline |
| `C.leader(x, y, w, label, value, vfg?, lfg?)` | `leader` | dotted leader, value right-aligned |
| `C.ticks(x, y, n, done, fg?, rest?, ch?, restch?)` | `ticks` | tick row |
| `C.progress(x, y, n, done, total, fg?, ch?, rest?, restch?)` | `progress` | tick row with `done/total`; returns the next column |
| `C.chip(x, y, label, id, kind?, w?)` | `chip` | one-row control; returns the next column |
| `C.flag(x, y, w, text, detail?)` | `flag` | `! text detail`; the detail only when it fits |
| `C.box(x, y, w, h, fg)` | `box` | hairline frame |
| `C.digits(x, y, text, fg?, w?, h?, gap?)` | `digits` | line digits; returns the width |
| `C.put(x, y, text, fg, bg?)` | `cv.put` | text with its own fg; bg kept when omitted |

Helpers: `U.tone(word)`, `U.mark(line)`, `U.age(ms, long?)` (`now`, `3m`/`3 min`, `2h`/`2 h`),
`U.arrow(facing)`, `U.filled(n, part, whole)`, `U.g` (glyph bytes), `U.chips` (chip colours),
`U.palette`, `U.stale`. The Big Tiles canvas methods (`header`, `tile`, `big`, `button`, ...) stay
for screens not ported yet.

## 13. Status

`U.status(model, w, h)` picks a layout by size. The model comes from `so-mod-display`'s gather;
see [display](../server-only/PROTOCOL.md#display).

- **Wall**, 96x32 and up (100x38, 164x81): alerts, a turtle table with position, fuel, ore and
  seen, jobs with busy, lane and grow, today and server side by side, drops with position and
  state, events with seconds. A rule at column 58, then the map thumbnail (`map.thumb`, at most
  48x30, 40x26 at 100x38) and the display list. Without a thumbnail the display list moves up.
  Turtles cap at 8 rows, drops at 5, events at 8. A frame over 15000 bytes redraws tight: 5 turtle
  rows, 5 events and a 40x26 thumbnail.
- **Room**, 52x22 and up (57x24): alerts on rows 3 and 4, turtles and jobs on the left, today and
  server on the right, drops in one row, events with minutes to the bottom.
- **Column**, 24x14 and up (51x19, 39x19, 26x20): one column. From 36 cells wide jobs follow the
  turtles and today and server sit side by side; narrower screens drop jobs and stack today and
  server. Blocks drop from the end when rows run out; spare rows go to events.
- **Tiny**, anything smaller (15x10): the header, short alerts and leaders for turtles, mining,
  ore, logs, disk and trees as they fit.

More rows than fit end with `+N more`; more alerts than fit end with `+N`. Alert rows are an
`alerts` button when the state module raised an alert. The pocket fallback (no panel module)
draws the same layout under `FLEET`.

## 14. Fixtures and the generator

A fixture is `WxH title`, then H text rows, H fg rows and H bg rows. Text is Unicode: the glyph
table above for control bytes and Latin-1 for 160-255. Two-layer fixtures (text, bg) from Big
Tiles still load. `tests/ui/render.lua` compares fg only where the cell is not blank.

```sh
python3 -I docs/ui/schematic/screens.py --fixtures            # rewrite tests/ui/fixtures
python3 -I docs/ui/schematic/screens.py --png DIR [names]     # PNGs with CC's own font
python3 -I docs/ui/schematic/screens.py --prototype DIR       # the unported prototype screens
```

PNGs need CC:Tweaked's `term_font.png`, which is not in this repo. The generator takes `--font`
(the png or the mod jar), `$CC_FONT`, or the first `cc-tweaked-*.jar` in a known mods folder.
Fixtures need no font.

To port a screen: write its layout in `schematic/<screen>.py` with the kit, add it to `FIXTURES`
in `screens.py`, take its data from a scene file the Lua test also reads, write the Lua twin, and
compare them in a test as `tests/ui/s0.lua` does for status. Remove the screen from
`prototype.py` and, if it had a Big Tiles fixture, add its name to `ported` in
`docs/ui/mockup-gen.py`.

## 15. Shop

`so-mod-shop.lua` draws the shop; `schematic/shop.py` is its twin and writes the `shop-*` fixtures
from `tests/ui/shop-stock.tsv`. See [shop](../server-only/PROTOCOL.md#shop) for the ids.

- **Header:** `SHOP items low find`, then `stock 21:14` from 52 cells, the time alone from 36. The
  time gives way first. Under 31 cells plus the right word the header keeps the tabs only; a
  `stale` that still does not fit moves to the footer. No storage room is a coral `missing`.
- **Rows under the header:** ITEMS has the category chip row (wrapping) and, for an open category,
  its sub chips. Under 52 cells these become two chips, `ores ▼` and `all ▼`, that open a picker:
  leader rows with item counts, in as many columns of 12 cells or more as the rows need. Subs that
  need more than two chip rows use the picker on wide screens too. LOW has `all low empty`. FIND
  has `> IRON_` with `del` and `clr` at the right and the keypad below, 13 keys a row at most.
- **Column head:** `item`, `stock` and `/h` are the sort control; the active one is a chip with `▼`.
  `/h` and the trend column need 36 cells.
- **List:** one row per item: the name in capitals, a dotted leader, the count, and the hourly
  change as `↑60` (muted) or `↓20` (amber). The count is white, amber when low and muted at 0.
  From 90 cells the list splits into two balanced columns with a rule between them.
- **Item:** from 52 cells the item opens as a right-hand pane behind a rule, so the list stays
  visible with the row selected; × closes it. Narrower screens give it the page and a `back` chip.
  The pane has the name, leaders for stock, stacks, last hour, category and sub, and craftable
  (above 0), then ORDER with `1 16 64` and `stack all` chips, then the recent orders as
  `• 16 sent  21:14` (green sent, muted delivered, coral failed). Under 13 rows it keeps the name, stock, last hour,
  ORDER and the orders.
- **Footer:** `1 of 2` and the `◄ ►` chips on the last row; a chip with nowhere to go is muted.
  Screens of 16 rows or more keep a blank row under the header and above the footer.

## 16. Pocket

The pocket role at 26x20 (26x19 for older clients); `so-mod-panel.lua` draws it and
`schematic/pocket.py` is its twin.

- **Tabs:** row 1 from column 1, ` FLEET  JOBS  SHOP  PAIR `, the active tab `0` on `7`, the
  others muted. A coral `•` sits inside FLEET while any flag exists. There is no role name.
- **FLEET:** status's column layout (section 13) under the tabs. Each alert row is an `alerts`
  button.
- **ALERTS** (a FLEET page): `ALERTS` with the count in coral, then every flag: a coral `!`,
  two rows of white text and two of muted detail, a blank row between flags. More than fit
  page with `◄` and `►` chips and a muted `n/m` on the last row.
- **JOBS:** MINING at row 3 and LUMBER at row 12, each a section with the state word at the
  right in its tone (a long hold reads as its first word). Mining: `|||||||··· 7/10`, `busy`,
  `lane` (the holder's arrow and id in blue), `min fuel` (`412 #6`, amber under 500). Lumber:
  `♠♠♠♠♠♠♠♠♠♣♣♣ 9/12`, `next grow`, `saplings`, `fuel`. Missing values are a muted `-`. START and
  STOP are 11-cell chips two rows under the facts; the one that does nothing now is muted. A
  missing job draws `not loaded` and grey chips without targets.
- **SHOP:** `> iron_` (muted prompt, teal cursor) with an `×` chip to clear, a hairline, then
  the matches as leaders, the count amber under 10 and muted at 0. The shown item sits on the
  panel colour with its `1` `16` `64` chips under it; the last order is on row 19, green when
  sent, coral when not.
- **PAIR:** the code in line digits 3 cells wide and 7 tall, a teal 18-cell tick row counting
  its five minutes down with `m:ss`, and NEW CODE on row 18. Without a code the digits read
  `------` in muted grey; `code in use` (amber) when another display holds one.

## 17. System screens

`so-mod-display.lua` draws the takeover and the unassigned page, `display.lua` the no-server
row; `schematic/system.py` is their twin.

- **Alert takeover:** a coral box around the screen. Row 3 holds a coral title chip
  (` #6 ORE CHEST FULL `) and the subject's position in white, or the position on row 4 when
  it does not fit. The detail follows, muted, after a blank row. Below it a crop of the map
  around the subject (`map.crop`, one block per cell, the subject inverted) fills down to five
  rows from the bottom, and row h-2 is a coral tick row of the time left out of 5 s. Margins
  are 4 cells from 40 columns up, else 2. Opened by a tap it has no tick row; any tap
  dismisses it. Without a crop (no map module, or it failed) the subject's facts take its
  place as leaders, 30 cells wide: `state`, `where`, `fuel`, `ore`, `seen` for a turtle, `kind`
  and `state` for a drop.
- **Unassigned:** the header holds `UNASSIGNED` (or the role whose module is missing) and the
  display id fills the screen in line digits, at most 9 wide and 11 tall, centred. Too small
  for digits, the id is plain text on row 3.
- **No server:** the client keeps the last picture and swaps the palette to `U.stale`, then
  draws row 1 on `2` (coral in that palette): ` NO SERVER  0:42` and `retry in 8 s` ending one
  cell from the right edge (`8s`, or nothing, when narrow). Only that row is redrawn each
  second.

## 18. Server terminal

51x19: the header `SO SERVER #1` with the uptime at the right, up to two alert flags, FLEET
(`turtles 4 ok · 1 lost` with the lost count coral, `displays`, `leases`) beside DISK (the
percentage on its section, a full-width tick row, `used`, `pair` with a pending code), then
LOG: each line a muted `hh:mm:ss`, a `•` mark in its tone and white text. Row 19 holds the key
hints, `[P] pair  [R] roles  [L] log`, with the keys teal. Under 48 columns DISK moves under
FLEET.

- **P:** `PAIR CODE`, the six-digit code in line digits 5x7, a teal tick row with `m:ss`, and
  `[P] new code  [Esc] cancel`.
- **L:** the whole log under `LOG` with its line count, `[Esc] back  [↑↓] scroll`.
- **R:** `DISPLAYS` with the count, then id, size (muted) and role (muted when unassigned),
  `+N more` when they do not fit, the last result above the prompt (two rows when long), and
  `> 6 shop_` with `[Enter] set  [Esc] back` at the right.
