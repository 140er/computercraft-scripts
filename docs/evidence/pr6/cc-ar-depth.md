# cc_ar 0.2.1 depth limitation

The installed mod uses ordinary depth-tested rendering for 3D lines and text.
The Lua API has no option to render these elements through blocks.
The requested through-wall x-ray behavior remains blocked on this mod version.

Inspected artifact:

- File `cc_ar-0.2.1.jar`.
- SHA-256 `479a5ebb06ee7be7c0c13279369e373bf628474daf1b7101fb5eb9f95aaa6ec2`.
- Native run `C:\Work\gemini-input\p2\evidence\pr6\gateB\native-priority`.

The following findings come from the installed class bytecode, inspected with
the existing JDK's `javap -c -p`.

- `ARLine3D.render` subtracts the camera's world position from the supplied
  start position. It requests `RenderType.LINES`. Coordinates are world
  coordinates, without an added controller offset.
- `ARText3D.render` also subtracts the camera's world position. It calls
  `Font.drawInBatch` with `Font.DisplayMode.NORMAL`, not a see-through mode.
- `ARRenderer.renderLevel` draws at `AFTER_PARTICLES`. Its dispatch pushes
  and pops the pose stack but does not disable depth testing.
- The renderer's availability check tests whether the player wears AR goggles.
  It has no separate 3D visibility toggle.
- `Config` builds an empty configuration specification. It defines no depth
  or x-ray setting.
- `ARControllerPeripheral` exposes `drawLine3D` and `drawText3D` without a depth
  argument. The remaining drawing methods cover 2D lines, rectangles, text,
  and item icons. No alternate through-wall method appears in its API.

Reproduce the inspection against the disposable test installation:

```powershell
$jar = 'C:\Work\mc-ssot-pr6-4eedb010\mods\cc_ar-0.2.1.jar'
Get-FileHash $jar -Algorithm SHA256
& C:\Tools\jdk-21\bin\javap.exe -classpath $jar -c -p `
  com.kito1z.cc_ar.client.elements.ARLine3D `
  com.kito1z.cc_ar.client.elements.ARText3D `
  com.kito1z.cc_ar.client.elements.ARRenderer `
  com.kito1z.cc_ar.Config
& C:\Tools\jdk-21\bin\javap.exe -classpath $jar -p `
  com.kito1z.cc_ar.blocks.blockentities.ARControllerPeripheral
```

The inspected `ar-xray.png` shows the 2D HUD and the solid fixture wall,
without turtle or ore outlines through the wall. The earlier `ar-hud.png`
looks down at the platform and wall. Although the setup teleported the player
to Y=70, that screenshot is consistent with the creative player falling
before capture. It does not establish that unobstructed 3D geometry failed.
The tall anchor's visible portion may also lie outside that camera view.

The client fixture now captures `ar-geometry.png` after removing only the
disposable wall. It retains the same camera as `ar-xray.png` and takes another
real F2 screenshot. That comparison still needs its next native run.
Neither successful element creation nor a screenshot filename proves x-ray.

Changing Lua coordinates cannot remove the mod's depth test. A client renderer
change or a compatible mod version with a supported see-through API is needed
for actual through-wall geometry. No mod binary was changed.
