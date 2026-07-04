# Isolation & scaling — decision record

Status: **planning**. Captures the tenant-isolation model, the trusted-vs-adversarial
decision, laptop↔EC2 parity, and the scale-out path for each component.

---

## 1. Isolation decision record

### Trust model (decided)
**Trusted-internal, accident-hardened.** Tenants are trusted colleagues (internal
apps, behind a VPN, low-sensitivity data). The threat is **accidental bad code** —
mistakes, not malice: memory leaks, runaway loops, fork bombs, disk-fill, runaway
LLM cost, an accidentally-public route, an accidentally-leaked secret. We
therefore **keep every blast-radius control and drop the anti-malice hardening**
(nobody escapes the kernel *by accident*).

Guiding rule: keep everything that **bounds the damage of a mistake** (limits,
quotas, budgets, default-deny, encryption, backups); drop the machinery whose only
job is defeating an **active attacker** (gVisor, rootless-build sandbox, strict
egress/anti-spoofing). Keep the **near-free** hardening as cheap insurance.

### The 5 moves (re-scoped for accidents)

**Move 1 — per-app limits — KEEP (via Coolify)**
- **Coolify per-app CPU/memory limits** — the core anti-accident control (stops a
  runaway loop / leak starving the box). Extra hardening (`--cap-drop`, read-only
  rootfs, non-root) via Coolify custom Docker options where supported.
- Ports not published — apps reachable only through Coolify's Traefik.
- ~~gVisor (`runsc`)~~ **DROPPED** — kernel escape is a malicious exploit; accidents
  don't trigger it. Standard `runc`.

**Move 2 — build → immutable image — via our heal loop + Coolify deploy**
Kiosk builds the image (build-verify-heal) with a **build timeout**, pushes it to a
registry; **Coolify deploys the image**. Every deploy is an **immutable artifact**
(reproducible, rollback = redeploy prior image, no drift). No rootless/Kaniko RCE
sandbox — an accidental bad build merely *fails*.

**Move 3 — network — via Coolify Destinations**
- **One Coolify Destination (Docker network) per tenant** — apps on different
  Destinations can't communicate, so this is the native per-tenant isolation
  mechanism (stops accidental cross-tenant / wrong-DB reach). Replaces the
  hand-rolled per-tenant network we'd have built.
- **KEEP** EC2 IMDSv2 + hop-limit 1 (one setting, near-free insurance).
- **RELAX** the strict egress allowlist / anti-spoofing (malice-only). Coolify's
  Traefik owns identity-header injection; oauth2-proxy middleware attaches via the
  app's custom labels.

**Move 4 — quotas on shared stores — KEEP**
Per-namespace size cap on sqld (+ monitoring); disk via per-app limits; per-key
rpm/tpm on litellm.

**Move 5 — secret encryption + cheap recovery — KEEP**
Envelope-encrypt tenant secrets in Postgres (KEK via age/KMS) — guards accidental
leak/dump. No HA — nightly volume snapshots + declarative rebuild + monitoring.

**LiteLLM per-tenant budgets — KEEP** (stops an accidental loop draining the budget).
**RBAC default-deny — KEEP** (an accidentally-exposed route stays closed).

### Compat-fallback policy — N/A
With gVisor dropped, apps run on the standard runtime — no `runsc` boot check, no
compat fallback. The build-verify-heal loop still runs the health check (on `runc`)
to confirm the app boots and serves before going live.

### Traceability (accident-focused)
| Accident risk | Bounded by |
|---|---|
| Noisy neighbor (cpu/mem/pid/disk) | Move 1 |
| Runaway build | Move 2 (timeouts/limits) |
| Accidental cross-tenant / wrong-DB access | Move 3 (net-per-tenant) |
| Accidental IMDS reach | Move 3 (IMDSv2 hop-limit) |
| Storage/DB starvation | Move 4 + Move 1 |
| Runaway LLM cost | LiteLLM budgets |
| Accidentally-public route | RBAC default-deny |
| Accidental secret leak | Move 5 (encryption at rest) |
| Shared-service SPOF/saturation | Move 4 + Move 5 (caps, backups) |

### Policy: customer-data apps do NOT run here
Because gVisor + a build sandbox are deliberately excluded (to keep Coolify simple),
the "arbitrary code on the shared host" risks (build-RCE, container escape) are
*contained, not eliminated*. Therefore **apps handling customer/regulated data (e.g.
booking/PNR) are not hosted on this tier** — they stay off-platform or move to a
separate hardened tier (gVisor + rootless build + strict egress). The kiosk flags
apps that declare customer data and blocks/escalates them. See `security-audit.md`.

### Accepted residual risks
1. **Compromise, not just mistakes, can escalate.** Without gVisor/build-sandbox/
   strict-network, an *externally compromised* app (dependency supply-chain, an RCE
   bug in tenant code) could reach the kernel, other tenants, or IMDS. Acceptable
   because apps are internal-only / behind VPN / low-sensitivity, and customer-data
   apps are excluded (above). Contained by network segmentation (see
   `security-audit.md` #4). **Trigger to harden a specific app** (gVisor + sandbox):
   internet-facing or handles sensitive data.
2. **Build-RCE on the build host** — mitigated by base-image allowlist + Trivy scan,
   not eliminated (real sandbox is bespoke). Same class as container escape.
3. Single-box availability (mitigated by fast rebuild + snapshots, not eliminated).
4. sqld per-namespace CPU not hard-capped (monitor; graduate heavy tenants).

### Deliberately NOT built (anti-over-engineering)
No gVisor/Firecracker/Kata, rootless-build sandbox, strict egress firewall,
Kubernetes, service mesh, custom CNI, per-tenant datastore instances, or
HA/multi-node — until a concrete trigger (adversarial tenants, internet-facing or
sensitive apps, scale) appears.

---

## 2. Laptop ↔ EC2 parity

Dropping gVisor makes parity trivial: **standard `runc` everywhere**, so the same
Coolify + platform services run on a laptop identically to EC2. The only remaining
differences are two near-free host settings.

| Layer | Laptop (Colima) | Remote EC2 | How parity is kept |
|---|---|---|---|
| Coolify engine (ingress/build/cron/lifecycle) | ✅ | ✅ | same Coolify both sides |
| Platform services (kiosk, litellm, oauth2-proxy, authz, sqld, postgres, redis) | ✅ | ✅ | same service definitions, only config differs |
| Destination-per-tenant, per-app limits | ✅ | ✅ | via Coolify |
| Runtime | `runc` | `runc` | standard everywhere — no `runsc`, no compat/perf gap |
| IMDSv2 hop-limit (Move 3) | N/A | ✅ EC2 setting | EC2-only, near-free |

**Local runtime: Colima** (a real Linux VM) runs the standard runtime with no extra
setup — no gVisor provision script needed anymore. Functional parity is 1:1; only
the EC2-only IMDS setting and disk-quota driver differ.

**Rule of thumb:** Coolify + the platform services bring up the whole thing; only a
couple of EC2 host settings sit outside it. Local and remote are effectively identical.

---

## 3. Scale-out path per component

Principle: everything is either **(a) stateless → horizontal replicas behind a
load balancer**, **(b) stateful shared store → managed cloud equivalent via
endpoint re-point**, or **(c) the tenant runtime → graduate to serverless
microVMs**. The Dockerfile-as-contract + env-only config makes each a re-point,
not a rewrite. Prefer vertical/managed before distributed-self-hosted.

| Component | Single box today | First scale step | Full scale | Trigger |
|---|---|---|---|---|
| **Tenant runtime** | Coolify on one server (`runc`) | **beefier server + raise per-app CPU/mem limits** (vertical); **add servers to the fleet + per-resource placement** (spread apps) | **Cloud Run / Fly / K8s** for an app needing replica-HA (Coolify replicas = v5) | app needs more power (vertical → easy) or replica-HA (→ graduate) |
| **Ingress / build / cron / lifecycle** | Coolify (single server) | Coolify multi-server fleet | managed ingress if ever needed | Coolify-provided — scales with the fleet |
| **DB isolation (sqld)** | 1 sqld, namespace per tenant | multiple sqld nodes; kiosk routes tenant→node; heavy tenants dedicated | **Turso Cloud** (managed, thousands of edge DBs) | sqld CPU/connection contention |
| **LiteLLM gateway** | 1 container | horizontal replicas behind LB (state in shared Postgres+Redis) | managed gateway | request/latency saturation |
| **Metadata Postgres** | 1 instance | vertical + split logical DBs | **RDS/Aurora** + read replicas | write/connection pressure |
| **Redis** | 1 instance | replica | **ElastiCache / Redis Cluster** | cache/rate-counter load |
| **Auth (oauth2-proxy + authz)** | 1 each | replicas behind LB (stateless / shared session store) | **Zitadel/Keycloak** for richer self-serve orgs | login volume / org-management complexity |
| **Kiosk** | 1 | stateless replicas behind LB; saga idempotent/queue-driven | same | provisioning concurrency |
| **Object storage** (if needed) | kiosk volume | MinIO | **S3 / R2** (re-point) | blob/upload volume |

**Key insight:** with Coolify, **vertical scale is the everyday lever** — a beefier
server + higher per-app limits handle "more powerful apps" with no re-architecture,
and adding servers to the fleet spreads the load. The only thing that forces a
*graduation* is an app needing **replica-based HA** (Coolify: v5) or ever going
**adversarial / internet-facing / sensitive** — then that one app moves to Cloud
Run/Fly/K8s. Because the Dockerfile+image is the contract, it's a re-point, not a
rewrite.
