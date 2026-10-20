# Reproduction notes

These are metadata/signature inventories, not decompiled mod bodies. Raw inspections stay outside the repository in `C:\Work\gemini-input\jar-evidence`.

DirectGPU inspection command (PowerShell):

```powershell
& C:\Tools\jdk-21\bin\javap.exe -classpath C:\mc-cc-test\jars\cc\directgpu-1.0.25-neoforge-1.21.1.jar -p -c -v com.tom.directgpu.DirectGPUPeripheral
```

Check RuntimeVisibleAnnotations for LuaFunction; match each method's Java signature and LocalVariableTable argument names. IArguments indicates a manually parsed Lua argument list, not a table argument. The metadata appendix lists 149 annotated public methods, excluding nonannotated overloads.

Additional inspected classes: DirectGPUConfig, DirectGPUPeripheral$MonitorInfo, ARControllerPeripheral, ARRenderer, ChatBoxPeripheral, GeoScannerPeripheral, Events, PeripheralsConfig, SphereOperation, BasePeripheral, FuelAbility, OperationAbility, ModemPeripheral, TurtleAPI, MonitorPeripheral and Classic Peripherals' WirelessModemPeripheralMixin. ZIP inventories covered all nine mod versions named in jar-sha256.txt; class inventories also covered peripheral classes of Tom's/Classic/ccpe/cc_modern/Turtlematic.

`craftos-probes.txt` comes from tests/review-probes.lua running as startup in `C:\Work\gemini-input\review-probes` with standardsMode and 4 MB disk. The probe was run through CraftOS-PC_console.exe --headless --directory C:\Work\gemini-input\review-probes --rom %LOCALAPPDATA%\computercraft-sandbox\craftos-2.8.3 --id 0. That disk's startup was subsequently replaced for a separate monitor API probe; rerun by copying the repo's review-probes.lua back to computer/0/startup.lua first.

`craftos-monitor-methods.txt` is the actual peripheral.getMethods result after periphemu.create("right","monitor") in CraftOS-PC 2.8.3. The wrapper has no screenshot method. This Lua expression was sandbox-verified; it is not a Minecraft-only API. The monitor window F2 capture route has not been verified.

Current hub capture is independently reproducible using tests/review-capture.ps1. It uses software GUI rendering and SDL dummy video, not --headless text output.
