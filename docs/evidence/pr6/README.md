# PR 6 evidence

The Linux Gate A run on bundle `4538c7db` passed. `lua5.2 tests/run.lua` printed `168 tests passed`. The CraftOS-PC 2.8.3 AR scenario passed six computers, three turtle emulators, 4,000,000-byte disks, and a full process restart. The transcript is [linux-2026-10-20.txt](gateA/linux-2026-10-20.txt). Gate B was not run.

cc_ar 0.2.1 depth-tests 3D lines and text and has no see-through API. World boxes are ordinary depth-tested outlines. The HUD says `Outlines stop at blocks`. A wall screenshot that shows no outlines matches the renderer. It is not a failed x-ray pass. See [the bytecode findings](cc-ar-depth.md).

Gate A passed 116 registered mock tests plus the standalone SSOT, navigation, mining, and AR checks. The CraftOS scenario used six computers, three turtle emulators, virtual modems, and 4,000,000-byte disks. It covered controller detach and replacement, ownership recovery, and full process restart. Results are in [mocks-final.log](mocks-final.log), [coverage.json](gateA/coverage.json), and [sandbox.log](gateA/sandbox.log).

```powershell
C:\Tools\lua52\lua52.exe tests\run.lua
powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox\run.ps1 -Scenario ar -Seconds 900 -DataRoot C:\Work\sbx-pr6 -Output C:\Work\gemini-input\p2\evidence\pr6\gateA\final-shared
```

The sandbox controllers have separate stores. `tests/ar-shared-owner.lua` separately verifies one shared store. Its stale-element regression failed before the production fix. The native shared-controller checks passed in [native-priority](gateB/native-priority/owner-result.json), including server death/reclaim, forwarded keys, detach/replacement, stale cleanup, and foreign namespace preservation.

![CraftOS HUD](gateA/ar-hud-emulated.png)

This is the emulated HUD. Its layout predates the final ownership cleanup fix; the layout did not change.

Real AP chat passed in [native-acceptance](gateB/native-acceptance/real-ap-chat.json). An unenrolled UUID caused no action. Authorized hidden and public commands each executed once. Replaying the hidden confirmation token caused no extra action. Only the disposable player's actual UUID was enrolled.

Both native runs passed element creation, three real turtles moving, zero drawing calls for unchanged frames, scoped cleanup, and Minecraft restart recovery. The renderer fixture uses real turtle telemetry and controlled ore positions matching placed blocks. It does not prove production ore ingestion or physical recall.

The linked-goggles [HUD](gateB/native-acceptance/ar-hud.png) is visible. The [wall image](gateB/native-acceptance/ar-xray.png) shows no through-wall geometry and is retained as failure evidence. The unobstructed image was empty because client shutdown raced F2 encoding. The capture helper now waits for a complete PNG and records its source path.

The later ownership assertion was inconclusive. Its [hub journal](gateB/native-acceptance/4-ar-owner.json) contains no drawing after the forwarded key, but the host test could compare a transient empty read against a counter. Every comparison now waits for fresh valid samples, and saves the key baseline and final state. The zero-mutation assertion is unchanged. The corrected run and native cached-role installation are pending under `gateB\native-verified`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ingame\run.ps1 -Scenario ar -Client -Timeout 1800 -Output C:\Work\gemini-input\p2\evidence\pr6\gateB\native-verified
```

Full raw evidence is under `C:\Work\gemini-input\p2\evidence\pr6\gateA` and `gateB`. The [decision trail](decisions.tsv) records earlier startup, transcript, scheduling, and polling failures. Failed runs remain preserved. A result's `visual` field means the requested image paths existed; human inspection is still required.

A recalled miner that is already outside the mining loop now walks home. The mock and the CraftOS scenario both cover that path. A real turtle returning across blocks, and a native install of every role, still need Gate B.

PR 4 charging and warehouse behavior is the code merged from main. PR 5 view roles stay unavailable until that branch is merged. A separate hub has no ore snapshot until PR 5. AR bounds record intent. Existing miner bounds enforce movement. UUID authorization starts empty. Interrupted bundle promotion requires manual offline repair.
