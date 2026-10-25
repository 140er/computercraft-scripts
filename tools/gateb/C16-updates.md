# C16 pinned worker updates

Run C16 on a merged server-only target at 20 TPS. The driver needs a strictly
older ancestor that already implements pinned worker updates. It selects that
ancestor from first-parent history and installs its actual files and revision
marker on ten new native turtles in one private driver world. It never invents
an old revision marker for current code. A target without a suitable ancestor
is Blocked. The usual load-wait admission applies before world preparation.

The host checks `https://api.github.com/rate_limit` without credentials. C16
requires the unauthenticated core limit of 60 and at least 40 remaining calls.
It checks again before simultaneous dispatch and records the remaining count
before, at dispatch and after, including after an interrupted check. Other users
of the shared quota can still make the real update attempts fail.

The ten requests use `SO.updateWorker` in one server invocation. Each worker
must acknowledge, hand off to its installed updater, call native `os.reboot`
and send a hello with the target revision on a later boot. The server must
confirm completion. The complete installed path set must match the worker role
manifest read independently from the target commit and its Git tree. Every
file must match the target bytes.
Each worker must make exactly four real API calls. The successful update uses
real GitHub ref, compare, tree and raw-file responses.

The budget probe uses one worker before the ten-worker batch. Its HTTP wrapper
returns 403 with `x-ratelimit-remaining` set by `--c16-fake-remaining`, default 0,
and `Retry-After: 60`. Allowed values are 0, 1 and 2, below the three calls still
needed after the first response. The injected request never reaches GitHub.
The installed updater must refuse, display `Update API refused` on the worker
terminal and preserve its installed files, revision, pairing, journal and
recovered configuration. Only `updateApiRetryAt` may change in this probe.
C16 removes the fake response and
clears that test cooldown before the real batch, then reboots the server to
clear the previous in-memory pending request.

The host selects a real commit from remote refs and verifies with
`git merge-base --is-ancestor` that it is outside server-only ancestry. The
ancestry probe sends an authenticated request for that SHA from the real
server. It requires worker acceptance, installer handoff, a real GitHub
comparison for that SHA and `Pinned revision ancestry refused` on the worker
terminal before reboot. Files, revision, pairing, journal and the complete
recovered configuration must remain unchanged. The worker must then send a
hello with its old revision on a later boot. An early worker refusal cannot
pass. Missing remote history or a suitable outside commit produces Blocked.
This probe consumes real API calls before the quota check for the ten-worker
batch; the remaining quota must still cover all 40 batch calls.

Pairing keys are generated only for these private fixtures and never enter
evidence. Hashes verify that the keys survive updates. Harmless park leases
must complete before the probes and after all ten updates. After the initial
leases, the driver reboots the fixture workers and requires a later boot's hello
at the baseline revision plus paired, idle server rows. A completed lease keeps
its worker deadline. Waiting for it to expire enters silence recovery and can
make an update request fail the busy guard. This fixture reset happens before
probe fingerprints and is separate from each update's required native reboot.
Refusal evidence also retains early errors and the final server lease state.
The final server rows must be paired and have no open, lost or uncertain lease state. Updates
require idle workers, so C16 does not inject an active lease at acceptance.

The optional bridge hook records only update replies, revision hellos, API
URLs, handoffs, boot counts and the terminal at reboot. It restores the test
bridge startup immediately before delegating to native `os.reboot`, because
the product updater installs its normal startup. It never replaces the
worker loop, updater, ancestry checks or reboot implementation. C16 leaves
the driver to clean up its private world through the normal lifecycle.
