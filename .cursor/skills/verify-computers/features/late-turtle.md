# Late storage turtle

The order computer boots first and keeps looking for the storage turtle. The turtle starts 25 seconds later, hosts the roomsorter protocol, and the order computer draws ORDER.

## Sub-features

- `client-waits` leaves the order computer running until a turtle answers.
- `turtle-late` starts computer 1 after a 25 second delay and then answers `stock`.
- `order-draws` shows ORDER on the terminal or the monitor window.

## How to get to it (user POV)

- Place the order computer, run `roomsorter install client`, and reboot it.
- Leave the storage turtle's chunk unloaded, or let that turtle finish booting later.
- Look at the order computer. The monitor shows ORDER once the turtle is up, without a second reboot.

## Driving it with verify-computers

Preconditions:

- Doctor printed `doctor PASS` and `capacity 1000000`.
- Computer 1's startup is `fake-turtle.lua` and its `delay` file is `25`.

- **Late turtle.** Run `.cursor/skills/verify-computers/bin/verify-computers run late-turtle`. The summary line is `roomclient PASS` and the screen contains `ORDER`.
- **Turtle started.** `docs/evidence/verify-computers/late-turtle-turtle-up.txt` contains `booted`.
- **Screen.** `docs/evidence/verify-computers/late-turtle-roomclient.txt` has the terminal text and, when the monitor window was used, a `-- monitor` section. ORDER in either section satisfies the check.

## Gotchas

- Headless CraftOS-PC does not boot computer 1 until the wrapper calls `periphemu.create(1, "computer")`. `turtle did not start` means the harness failed. Fix the harness before calling it a product failure.
- The client looks up the turtle for about 2 seconds, then waits 15 seconds for a stock broadcast. A turtle that waits 25 seconds is later than that. Current alpha prints `No storage turtle found` and returns, so ORDER is missing and the line is FAIL. Report it and do not change `roomsorter.lua` here.
- Because the client returns first, the dump can show `booted` without `up`. The turtle was still inside its 25 second wait when the computer shut down.
- The modem patch makes `isWireless()` true on the order computer. The fake turtle creates its own modem and hosts `roomsorter`.
- `wh2.cfg` is not written. The peripheral-proxy failure in `wh2-program.lua` stays latent and is not this scenario.
