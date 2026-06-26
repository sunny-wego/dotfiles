# Handler: security

Trust boundaries, secrets, and abuse. Runs when the diff touches auth, secrets,
crypto, signature verification, untrusted input, or bot/loop/abuse guards.

**Owns:** authn/z gaps, secret handling, signature/HMAC/crypto correctness,
injection (SQL/command/path), SSRF, loop/abuse guards, privilege scope, replay,
constant-time comparison.
**Not this:** general correctness (→ correctness) unless the bug is a security
boundary.

## What to look for
- **Signature / HMAC verification:** computed over the *raw* bytes before
  parsing? Constant-time compare? Correct algorithm and encoding? Fail-closed when
  a secret is absent — and is the *failure mode* of "no secret" acceptable
  (PR-223 fails closed correctly, but a missing secret then 500s every delivery →
  ties to resilience)?
- **Loop / abuse guards:** what stops the system triggering itself? If the guard
  rests on one field (PR-223 uses `sender.type == "Bot"`), is that field
  guaranteed for every identity the bot can act under? A guard that fails open on
  an unexpected identity is the concern.
- **Secret handling:** secrets logged, echoed in errors, returned in responses,
  or committed; a default/dev secret that could reach prod.
- **Injection & traversal:** untrusted input flowing into SQL, shell, file paths,
  or templates without parameterization/escaping.
- **SSRF / outbound:** a URL/host from untrusted input used to make a request.
- **Authz scope:** an endpoint/token broader than it needs; a check that
  authenticates but doesn't authorize the specific resource.
- **Replay:** is a valid signed request replayable? (Dedup/nonce mitigates.)

## How to verify (Tier 1)
- For crypto/signature: unit-test the verifier with tampered body, wrong algo
  prefix, wrong secret, and a valid signature; show accept/reject. Capture →
  `confirmed`.
- For a loop/abuse guard: feed a payload with the bypassing identity and show it
  passes the guard.
- Don't attempt live exploitation of anything outside the throwaway sandbox →
  `hypothesis` with a precise `verify`.

## Emit
`concern` = the boundary that can be crossed and the consequence; `question` asks
what guarantees the boundary holds (e.g. "is the bot always `type==Bot`?"). Real
auth/secret/data-exposure issues are `severity: high` even as a hypothesis.
