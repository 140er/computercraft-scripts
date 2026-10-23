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

Bytes 16-31 pass `so-proto` serialisation, compact rows and the client's `term.blit` unchanged
(`tests/ui/s0.lua`). Monitor sync in game is still to be checked in Gate B.

## 10. The map

- **Cells:** a text cell covers `sx` by `sz` blocks. Its glyph comes from the block adjacencies
  inside it: mostly along x gives `-`, mostly along z `|`, both `+`. Dug cells are solid and steel
  `3`; planned cells are dotted (`·`, `¦`) and muted; held cells are blue. Dug pieces off the mine
  geometry of six blocks or fewer draw as one steel `·`.
- **Scale:** `sx` from 1, 2, 3, 4, 6, 8 and up. `sz` snaps to a divisor or multiple of the branch
  gap, and the view top aligns so every branch lands on the first block row of its cell. The two
  axes scale separately, so every branch is exactly one row.
- **Markers:** turtles in their state colour, `º` shaft, `@` server, `•` and `×` chests, trees inside
  a hairline farm outline.
- **Labels:** placed greedily, turtles first, then server and drops, then the farm count. Right,
  left and the diagonals are tried; a label may not touch another marker or label, and covering a
  passage costs more than empty ground. Ok turtles show only their id, others id and state. From
  `sx` 3 only ids remain and plain chests lose their labels; a broken chest is always labelled.
- **Branch numbers:** muted, west of the spine when free, or at the left edge when the spine is off
  screen.
- **Controls:** all in the top row: `MAP`, `FIT`, `- +`, `◄ ▲ ▼ ►`, then `▼ ALL ▲` at the right. On the
  pocket, FIT and the level stay on top and pan and zoom move to the bottom row.
- **Taps:** a tapped marker is inverted and gets a callout with a connector. Zoom keeps the
  selected block in place.

`schematic/mapdraw.py` is the prototype of the cell pass and label placer.

## 11. Frame size

Frames stay under the 16 KB wire limit. `D.compact` lets a blank cell join the previous run
whatever its fg, so planned dots and labels do not split runs at every space. The 164x81 route A
map fixture is 12.2 KB with that rule and 14.6 KB without it. Every row with content costs about
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
