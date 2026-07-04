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

**Move 1 — "tenant sandbox profile" on every launch — KEEP**
- Resource caps: `--cpus`, `--memory`+`--memory-swap`, `--pids-limit`, block-I/O
  weight, `--storage-opt size=` (disk quota). ← the core anti-accident control.
- Hardening: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, read-only
  rootfs + small writable tmpfs, non-root user.
- No published ports — reachable only via Traefik.
- ~~Move 1a `--runtime=runsc` (gVisor)~~ **DROPPED** — kernel escape is a malicious
  exploit; accidents don't trigger it. Standard `runc` everywhere.

**Move 2 — build — DOWNGRADE**
Build on the host/Coolify Docker daemon with **timeouts + resource limits** (so an
accidental runaway build doesn't hog the host). The rootless/Kaniko RCE sandbox is
**dropped** — an accidental bad build merely *fails*, it doesn't attack the host.

**Move 3 — network — DOWNGRADE (keep the near-free parts)**
- **KEEP** one Docker network per tenant (`litellm` + `sqld` multi-homed; datastores
  + control-plane never on a tenant network) — stops *accidental* cross-tenant /
  wrong-DB access.
- **KEEP** EC2 IMDSv2 + hop-limit 1 (one setting, near-free insurance).
- **RELAX** the strict nftables egress allowlist and the anti-spoofing posture
  (those defend against malice). Traefik still owns identity-header injection.

**Move 4 — quotas on shared stores — KEEP**
Per-namespace size cap on sqld (+ monitoring); per-bucket quota on MinIO; disk via
Move 1; per-key rpm/tpm on litellm.

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

### Accepted residual risks
1. **Compromise, not just mistakes, can escalate.** Without gVisor/build-sandbox/
   strict-network, an *externally compromised* app (dependency supply-chain, an RCE
   bug in tenant code) could reach the kernel, other tenants, or IMDS. Acceptable
   because apps are internal-only / behind VPN / low-sensitivity. **Trigger to
   re-add gVisor for a specific app:** it becomes internet-facing or handles
   sensitive data.
2. Single-box availability (mitigated by fast rebuild + snapshots, not eliminated).
3. sqld per-namespace CPU not hard-capped (monitor; graduate heavy tenants).

### Deliberately NOT built (anti-over-engineering)
No gVisor/Firecracker/Kata, rootless-build sandbox, strict egress firewall,
Kubernetes, service mesh, custom CNI, per-tenant datastore instances, or
HA/multi-node — until a concrete trigger (adversarial tenants, internet-facing or
sensitive apps, scale) appears.

---

## 2. Laptop ↔ EC2 parity

Dropping gVisor makes parity trivial: **standard `runc` everywhere**, so the whole
stack runs via `docker compose up` on a laptop identically to EC2. The only
remaining differences are two near-free host settings.

| Layer | Laptop (Colima) | Remote EC2 | How parity is kept |
|---|---|---|---|
| traefik, authelia, control-plane, litellm, sqld, postgres, redis, minio, ofelia | ✅ compose | ✅ compose | identical file; only `.env` differs |
| Network-per-tenant, resource limits, quotas | ✅ | ✅ | applied at container launch |
| Runtime | `runc` | `runc` | standard everywhere — no `runsc` install, no compat/perf gap |
| IMDSv2 hop-limit (Move 3) | N/A | ✅ EC2 setting | EC2-only, near-free |
| Disk-quota storage driver (Move 1) | best-effort | ✅ | storage-driver dependent; degrades locally |

**Local runtime: Colima** (a real Linux VM) runs the standard runtime with no extra
setup — no gVisor provision script needed anymore. Functional parity is 1:1; only
the EC2-only IMDS setting and disk-quota driver differ.

**Rule of thumb:** compose brings up the whole thing; only a couple of EC2 host
settings sit outside it. Local and remote are effectively identical.

---

## 3. Scale-out path per component

Principle: everything is either **(a) stateless → horizontal replicas behind a
load balancer**, **(b) stateful shared store → managed cloud equivalent via
endpoint re-point**, or **(c) the tenant runtime → graduate to serverless
microVMs**. The Dockerfile-as-contract + env-only config makes each a re-point,
not a rewrite. Prefer vertical/managed before distributed-self-hosted.

| Component | Single box today | First scale step | Full scale | Trigger |
|---|---|---|---|---|
| **Tenant runtime ("serverless docker")** | Docker (`runc`) on host | multi-node via Nomad/Swarm; control-plane schedules across hosts | **Cloud Run / Fly Machines / Knative** — managed microVMs, scale-to-zero, Firecracker isolation | RAM ceiling, "all-apps-down" unacceptable, or an app goes internet-facing/sensitive |
| **MinIO** | single node | distributed MinIO (multi-node erasure coding) | swap endpoint → **S3 / R2** (S3-API, re-point) | disk/throughput limits |
| **DB isolation (sqld)** | 1 sqld, namespace per tenant | multiple sqld nodes; control-plane routes tenant→node; heavy tenants get dedicated | **Turso Cloud** (managed, thousands of edge DBs) | sqld CPU/connection contention |
| **LiteLLM gateway** | 1 container | horizontal replicas behind LB (state already in shared Postgres+Redis) | managed gateway | request/latency saturation |
| **Postgres (platform/litellm/authelia)** | 1 instance | vertical + split 3 logical DBs onto separate instances | **RDS/Aurora** + read replicas | write/connection pressure |
| **Redis** | 1 instance | replica | **ElastiCache / Redis Cluster** | cache/rate-counter load |
| **Traefik ingress** | 1 | replicas behind L4 LB (ALB/NLB); switch provider from Docker socket to shared config | managed ingress | ingress throughput |
| **Authelia** | 1 | replicas + shared session store (already Postgres/Redis) | **Zitadel/Keycloak cluster** for richer org RBAC | login volume / RBAC complexity |
| **Build pipeline** | 1 builder | pool of BuildKit build workers | **Depot** (managed builds) | build queue latency |
| **Control-plane** | 1 | stateless replicas behind LB; saga must be idempotent/queue-driven | same | provisioning concurrency |
| **Cron (ofelia)** | 1 | — | **Temporal / self-hosted Trigger.dev** | job volume/reliability needs |
| **Host/compute** | 1 EC2 | autoscaling worker pool + orchestrator | go managed serverless, skip node mgmt | capacity |

**Key insight:** graduating the *tenant runtime* to serverless microVMs (Cloud
Run/Fly/Knative) is the highest-leverage step — it restores **scale-to-zero** (lost
on the single box), removes the compute SPOF, **and** provides **Firecracker-grade
isolation** if the trust model ever hardens (adversarial or internet-facing apps),
without adopting gVisor on the box. Because the Dockerfile is the contract, it's a
re-point.
