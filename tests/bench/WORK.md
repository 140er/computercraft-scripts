# P0 work record

The accepted plan fixes the scope. These probes decide whether the listed operations work within the seven-second watchdog on Cobalt and CraftOS-PC.

## Prototype playbook

1. Scope the decision the prototype exists to make.
2. Gather references when the design space is open.
   Skip. The accepted plan selects ccryptolib and the required platforms.
3. Build throwaway in an isolated scratch dir, separate from production source.
4. When comparing alternatives, build them behind one switcher, each variant labeled.
5. Verify on the matching surface.
6. Present alternatives, tradeoffs, and a recommendation.

The probes remain rerunnable test instruments under `tests/bench`. Production code does not load them.

## Throughput checkpoint

- Blocking first steps. Read the plan, inspect the existing test runners, pin ccryptolib, and create a disposable server.
- Independent workstreams. One helper owns only the contract. The parent owns probes and evidence.
- Shared mutable state. Only the parent controls the disposable run and client capture. No helper edits a runner.
- Smallest safe decomposition. One measurement owner keeps timing, world state, and screenshots in sequence.

## Probe design

Each result records its name, input bytes, elapsed milliseconds, returned values, operation count, rejection count, and errors. Crypto samples retain individual timings. Results distinguish completion from a failed check. Yield counts come from coroutine suspension, with the longest interval between suspensions compared against 7000 ms.

An independent script for every measurement would duplicate result handling and make timeout failures hard to compare. One probe registry with a shared result writer keeps the measurements consistent. Probe-specific assertions remain beside the operation.

The expected claim is limited to whether the pinned library and selected inputs complete within the watchdog on each recorded runtime. The VM is shared and saturated. Timings do not establish a general speed ratio between runtimes.

## Decisions

| Evidence | Decision |
| --- | --- |
| Cobalt completed 65 crypto samples with a maximum uninterrupted interval of 122 ms. | Keep upstream crypto unchanged. Bound work between requests in later PRs. |
| Generated Ed25519 signatures differed from the RFC bytes but verified. | Verify generated signatures outside the timed region. Keep independent RFC verification. |
| Cobalt charged 500 bytes per small file and directory. CraftOS charged content bytes only. | Use Cobalt for storage admission measurements. Keep the emulator discrepancy visible. |
| Starbound regeneration and charging both obscured fuel decreases during successful moves. | Fuel alone cannot resolve movement unless both sources are excluded. |
| A command file was read during upload. | Read the uploaded bytes back before writing a separate ready marker. |
| Two CraftOS child boots reported BIOS parser failures. | Start each computer in its own process. Preserve the failed attempt. |
| Native screenshots sometimes captured a later progress screen. | Hold the result screen before and after capture, outside the timer. |
| Another session owns the running Minecraft client. | Wait through the client-lock helper. Do not stop a process P0 did not start. |

The installed pstack does not contain the referenced `deslop` skill. The
parent reviewed the test diff directly for redundant code and comments.
The vendored source and copied evidence remain unchanged by prose cleanup.
The referenced Comment Sicko agent is also absent from the installed pstack.
The parent reviewed the authored code directly. It contains no new explanatory
code comments to remove. No constraints were left enforced only by a comment.
