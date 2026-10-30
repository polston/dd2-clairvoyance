---
name: verified-live-handoff
description: Prevent premature handoff and live regressions when changing Clairvoyance, especially after a reported failure or before a Reset Scripts request.
---

# Verified Live Handoff

Convert corrections into durable prevention and continue through observable
whole-product verification.

1. On a reported failure, recover live state, reproduce it, add a RED regression,
   make it GREEN, and retain the test.
2. Add or strengthen the durable layer that would have prevented the handoff:
   an executable acceptance command, workflow rule, test, or narrow skill. A
   promise about future behavior is not remediation.
3. Prepare the post-reset acceptance command, then invoke Reset Scripts through
   the reviewed `focus.ps1` / `shot.ps1` / `input.ps1` path. A ban on Computer
   Use does not prohibit this narrow project automation. Ask the operator only
   when the game window or exact button cannot be resolved safely. If operator
   action is genuinely required, their `done` is an intermediate event: run the
   acceptance command immediately and continue the active plan.
4. Validate the complete focused-objective projection, not only the provider
   being changed. Unit tests, deployment, or a provider-local negative never
   substitute for the whole-product live gate.
5. Do not return control after fixing a subtask while requested work remains.
   Handoff only for a necessary subjective decision, an exhausted external-state
   blocker, or verified completion of the full requested outcome.

At closeout, report the retained regression, executable live gate, live result,
remaining scope, and intentionally untouched state.
