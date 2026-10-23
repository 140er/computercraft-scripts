# Wave 1 UI cleanup evidence

Reference images are in `~/work/gateb-driver/references-fa4babb/`.
No Minecraft server was started for this change. C3 and C13 need fresh Gate B
captures at the orchestrator's discretion.

## HUD placement

`C13-goggles-overview.png` and `C13-turtle-label.png` are 1280 by 720.
The Difficulty frame occupies approximately x=18..224 and y=19..63.
The first HUD bar begins at physical x=12, matching GUI x=4 at scale 3.
The tile label begins at physical x=24, matching GUI x=8. Thus the overlay's
bottom is about GUI y=21 in these captures. Moving to y=36 would clear that
capture, but gives little room if another overlay uses fixed physical pixels
at a smaller GUI scale.

The HUD starts at GUI `(4,72)`. Its top is physical y=72, 144, 216 or 288 at
scales 1 through 4. Each clears both the measured physical bottom of 63 and
the measured GUI bottom of 21. This covers the reference overlay, rather than
arbitrary mod layouts or user configurations. The 56-unit tile widths,
eight-unit gaps, four-unit bars and four-unit text inset remain from #177.
The five-second alert occupies the HUD's first 14-unit row. Retirement text
follows the tile row with four units of clearance.

## cc_ar API audit

The installed client `cc_ar-0.2.1.jar` has SHA-256
`479a5ebb06ee7be7c0c13279369e373bf628474daf1b7101fb5eb9f95aaa6ec2`.
CFR 0.152 was used locally to inspect these methods:

- `ARControllerPeripheral.drawRect2D` forwards x1, y1, x2, y2 to `ARRect2D`.
  Its renderer passes those corners directly to `GuiGraphics.fill`. The old
  HUD passed width and height as x2 and y2. This caused reversed rectangles
  and oversized bars. Tests now check the actual corner coordinates.
- `ARControllerPeripheral.drawText3D` forwards the whole string unchanged.
  `ARText3D.render` calls Minecraft's `font.drawInBatch` once for that string,
  after a uniform `size * 0.03` transform. There is no per-glyph spacing knob.
  The adjacent `#4` glyphs in `C13-turtle-label.png` have normal proportions.
  Scattered O/F marks are separate drop labels at separate world positions.
  #183's size 0.5, short strings and 0.25-block stack gap stay unchanged.
  C13's retake remains the visual check for world labels.

## Fixtures and checks

Fixtures change because instructional text and repeated status sub-lines are
removed. PAIR is a three-row teal button that opens the panel pair page.
AR toggles show ON or OFF directly. Pairing keeps the code and countdown.
Data such as lost workers, broken drops and ore increments remain visible.
The mockup generator and spec section 7.1 were regenerated together.

The direct Linux run passed 84 checks across UI0, UI1, UI2a, UI2b, UI2d, UI3a,
UI3b, UI3c and UI5a, with no skips. The tests include drawn-button pairing,
alert expiry, opposite-corner rectangles, label x ranges, consent placement
and GUI scales 1 through 4. Final suite evidence is reported in the PR.
