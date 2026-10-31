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
3. Prepare the post-reset acceptance command, then run `just reset-scripts`.
   It installs and hash-checks the probe harness, resolves the unique semantic
   ScriptRunner target without moving the physical cursor, and requires ordered
   reload/readiness evidence. Never use `focus.ps1`, `shot.ps1`, `input.ps1`,
   Computer Use, guessed keys, or guessed coordinates for Reset Scripts. If the
   exact target cannot be proved, fail closed instead of asking for a click.
4. Validate the complete focused-objective projection, not only the provider
   being changed. Unit tests, deployment, or a provider-local negative never
   substitute for the whole-product live gate.
5. Do not return control after fixing a subtask while requested work remains.
   Handoff only for a necessary subjective decision, an exhausted external-state
   blocker, or verified completion of the full requested outcome.

At closeout, report the retained regression, executable live gate, live result,
remaining scope, and intentionally untouched state.
