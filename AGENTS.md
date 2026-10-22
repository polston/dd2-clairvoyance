# Agent rules — Clairvoyance

1. **No personal or secret data in this repo, ever** — tracked files, history, commit
   metadata, fixtures. Covered: credentials, emails, real names, account/machine
   usernames, LAN IPs, hostnames, MAC addresses, absolute paths containing a
   username, session IDs, harvested session history, other local projects' paths.
   If found: stop and report — no silent scrubbing, no committing around it.
2. Never create a remote or push without the operator's explicit instruction.
3. Spec: `docs/SPEC.md`. `docs/` (SPEC.md, plans, ROADMAP.md) is a separate local git
   repo, gitignored here and never pushed; roadmap and spec edits are committed there.
4. Third-party reference sources live in `reference/` (gitignored, never committed).
