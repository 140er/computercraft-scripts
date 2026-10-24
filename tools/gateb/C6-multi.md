# Proposed C6 variant with two lumber turtles

The orchestrator runs this on a disposable Gate B world when G6 is ready. This
proposal does not start a server or claim in-game evidence.

1. Clone the stopped C6 template. Add a second paired axe worker named `lumber2`
   outside the farm and every chest approach. Keep the existing wood, fuel and
   sapling points. Provision both sapling species and enough fuel for both
   workers. Save native poses, chest inventories and the cold farm allowlist.
2. Stop lumber, configure the existing farm, and anchor both ids through `add`.
   Confirm both remain in `so-data/lumber/job.turtles`. Start once.
3. Sample both native positions and journals, reservations, saved worker rows,
   chest inventories and log events every half second. Capture the lumber
   screen at 26x20 and 29x12 and press its drawn START, STOP, SETUP and BACK
   buttons. Both ids must appear without a page change.
4. Stop after every original root contains the matching sapling and every native
   log has reached the wood chest. Compare all successful dig cells with the
   cold allowlist. No log cell may occur under both worker ids. The delivered
   inventory increase, `lumber.logs` total and saved job count must agree with
   the original native log count. Check each spot's reservation has one owner
   throughout felling and replanting. Neither turtle may enter the other's
   occupied cell. At a shared chest, the older ticket enters first and retains
   its access column until its return leaves it.
5. Reset the private world. Cut power to the server with both workers active
   mid-round. Restart it and verify a recovery park and journal-frame pose for
   each worker before its next movement. Finish the farm and repeat the exact
   dig, replant and delivery checks. Include a cut during chest transfer to
   check delivery accounting around a lost report.
6. Reset again. Stop one active worker mid-tree while the server stays on.
   Its unknown route and physical cell must stay reserved. The other worker
   must harvest, replant and unload other trees. Restore the missing worker,
   confirm its recovery park, and finish its tree without a second delivery
   count. Repeat with the missing worker queued at a chest. A physically
   occupied single access cell must stay protected until the worker returns.

Keep the samples, native block snapshots, event history, terminal frames and
logs under the variant's evidence directory. C4 and C10 saved-frame readers
also understand the new per-worker lumber rows. Their legacy fixture recordings
remain readable.
