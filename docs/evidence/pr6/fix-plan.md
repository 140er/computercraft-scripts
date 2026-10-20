# PR 6 fix run

The run passes only after the reviewed defects have regression tests, the role installer leaves exact role file sets, and both gates pass on the final merged source. Native gaps remain failures.

The work follows the poteto bug-fix and feature playbooks.

1. Reproduce it yourself on the matching surface via the control skill.
2. Binary-search the cause.
3. Plan the fix.
4. Verify on the same surface.
5. Stage the commits so the failing repro lands before the fix in git history.
6. Run Opening a PR.

The last step updates PR 28. It does not create another PR or merge.

The throughput checkpoint is as follows.

- Blocking first steps. Read the inherited failures, native evidence, current main, and gate-depth requirements before changing the tests.
- Independent workstreams. Installer files, AR projection, and chat authorization have separate owners. The root owns host adapters and gate evidence.
- Shared mutable state. The authorization worker owns server.lua, hub.lua, and ssot.lua. The AR worker sends changes for those files to that owner. Git operations run only after writers pause.
- Smallest safe decomposition. Three workers handle the production fixes. One coordinator integrates and runs both gates.

The remaining work is ordered as follows.

- Preserve the prior native findings and capture regression failures.
- Merge current main to use the real charging runtime.
- Fix the shared name and UUID policy, AR enrolment, chat rate limits, and recharge.
- Fix bounded AR selection and separate rendering from network event handling.
- Add the role manifest and transactional pruning without deleting user state.
- Wait for PR 5's fix summary, merge its pushed branch, and resolve shared code and keys.
- Regenerate the manifest and run the complete mock, sandbox, and capture checks.
- Run the same native scenario on a disposable box or VM server, with client capture under its lock.
- Record each applicable depth requirement and every unmet requirement.
- Review, push normally, update PR 28, and rewrite the external summary.

The native renderer and wearer capabilities are open verification limits. The previous bytecode evidence reports depth-tested geometry and no wearer-status API. Tests must not substitute simulated success for either requirement.
