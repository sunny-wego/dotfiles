# Isolation & scaling — decision record

Status: **planning**. Captures the tenant-isolation model, the trusted-vs-adversarial
decision, laptop↔EC2 parity, and the scale-out path for each component.

---

## 1. Isolation decision record

### Trust model (decided)
**Possibly adversarial** — tenants are non-engineers shipping LLM-generated code.
Rarely malicious, frequently *accidentally* hostile (leaks, runaway loops, huge
uploads). Threat = careless/occasionally-malicious **insiders**, not determined
external attackers. This makes gVisor proportionate and Firecracker/Kata
over-engineering (deferred).

### The 5 moves
All five apply in both trust modes. Only **Move 1a** is adversarial-only.

**Move 1 — one "tenant sandbox profile" on every container launch**
- Resource caps: `--cpus`, `--memory`+`--memory-swap`, `--pids-limit`, block-I/O
  weight, `--storage-opt size=` (disk quota).
- Hardening: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, read-only
  rootfs + small writable tmpfs, non-root user.
- No published ports — reachable only via Traefik.
- **Move 1a (adversarial):** `--runtime=runsc` (gVisor) on tenant runtime
  containers. Raises the shared-kernel escape ceiling.

**Move 2 — sandboxed build**
Rootless BuildKit/Kaniko in an ephemeral container, no host daemon socket, egress
limited to package mirror + registry. Kills build-time arbitrary code execution.

**Move 3 — network-per-tenant + three firewall facts**
- One Docker network per tenant. `litellm` + `sqld` multi-homed onto each tenant
  network; `postgres`/`redis`/`minio`/`control-plane` never on a tenant network.
- Host nftables: from tenant bridges DROP → RFC1918 and → `169.254.169.254`,
  ALLOW → internet (or allowlist).
- EC2 IMDSv2 + hop-limit 1.
- Traefik strips inbound `Remote-*` headers and is the only injector.

**Move 4 — quotas on shared stores**
Per-namespace size cap on sqld (+ monitoring); per-bucket quota on MinIO; disk via
Move 1; per-key rpm/tpm already on litellm + process caps.

**Move 5 — shrink the crown jewel; accept SPOF with cheap recovery**
Envelope-encrypt tenant secrets in Postgres (key from host/KMS); short-lived
tenant tokens; control-plane under the sandbox profile. No HA — instead nightly
volume snapshots + declarative rebuild + monitoring/alerts.

### Compat-fallback policy (decided): deny by default
When an app fails to boot under `runsc`, the deploy is **denied by default** —
the heal loop first attempts an automatic fix (swap native dep, drop the
offending feature); only if that fails does it deny. An **admin-approved
allow-on-`runc`** is the sole exception: a deliberate, logged decision per app,
never automatic. The boot check reuses the build-verify-heal health step under
gVisor, so compat is tested per app for free.

### Traceability
| Risk | Fixed by |
|---|---|
| Shared-kernel escape | Move 1a |
| Build-time RCE | Move 2 |
| Noisy neighbor (cpu/mem/pid/disk) | Move 1 |
| East-west spoofing / datastore access | Move 3 |
| Header spoofing | Move 3 + Move 1 |
| IMDS credential theft | Move 3 |
| Egress exfil / SSRF | Move 3 |
| Storage/DB starvation | Move 4 + Move 1 |
| Control-plane secret blast radius | Move 5 |
| Shared-service SPOF/saturation | Move 4 + Move 5 |

### Accepted residual risks
1. Single-box availability (mitigated by fast rebuild + snapshots, not eliminated).
2. sqld per-namespace CPU not hard-capped (monitor; graduate heavy tenants).
3. gVisor perf/compat overhead (proportionate cost of kernel isolation).

### Deliberately NOT built (anti-over-engineering)
No Kubernetes, service mesh, custom CNI, Firecracker/Kata, per-tenant datastore
instances, or HA/multi-node — until a concrete trigger appears.

---

## 2. Laptop ↔ EC2 parity

The **application stack runs entirely via `docker compose up` on a laptop**,
identical to EC2. Parity holds for all functionality; the difference is a thin,
**env-gated host layer** of isolation controls that live *outside* compose
(applied by host provisioning) and degrade/no-op locally.

| Layer | Laptop | Remote EC2 | How parity is kept |
|---|---|---|---|
| traefik, authelia, control-plane, litellm, sqld, postgres, redis, minio, ofelia | ✅ compose | ✅ compose | identical file; only `.env` differs |
| Network-per-tenant, socket-proxy | ✅ | ✅ | applied at container launch |
| Resource limits (Move 1) | ✅ | ✅ | launch profile |
| **gVisor runtime (Move 1a)** | **Colima VM: ✅** (`runsc` installed via provision script) · stock Docker Desktop: ✗ | ✅ | **`TENANT_RUNTIME` env** (`runsc` both sides for compat parity, or `runc` locally for fast iteration); perf still validated on EC2 |
| nftables egress (Move 3) | skipped/no-op | ✅ host provisioning | host-level, not compose; declarative via user-data/ansible |
| IMDSv2 hop-limit (Move 3) | N/A | ✅ EC2 setting | EC2-only |
| Disk-quota storage driver (Move 1) | best-effort | ✅ | storage driver dependent; degrades locally |

**Local runtime: Colima.** macOS dev uses **Colima** (a real Linux VM), so `runsc`
runs locally on the `systrap` platform (no nested KVM needed) — install it via a
Colima **provision script** so every dev gets it. This closes the parity gap:
gVisor **compat** can be tested on the laptop. gVisor **performance** is still
validated on EC2 (Colima's VM + systrap is slower; EC2 can use the KVM platform).

**Rule of thumb:** compose brings up the *app*; a thin host-provisioning layer
applies the *isolation controls*. Both are declarative. With Colima+`runsc`,
functional parity is 1:1; only performance numbers differ from EC2.

---

## 3. Scale-out path per component

Principle: everything is either **(a) stateless → horizontal replicas behind a
load balancer**, **(b) stateful shared store → managed cloud equivalent via
endpoint re-point**, or **(c) the tenant runtime → graduate to serverless
microVMs**. The Dockerfile-as-contract + env-only config makes each a re-point,
not a rewrite. Prefer vertical/managed before distributed-self-hosted.

| Component | Single box today | First scale step | Full scale | Trigger |
|---|---|---|---|---|
| **Tenant runtime ("serverless docker")** | Docker + gVisor on host | multi-node via Nomad/Swarm; control-plane schedules across hosts | **Cloud Run / Fly Machines / Knative** — managed microVMs, scale-to-zero, Firecracker isolation (makes gVisor moot) | RAM ceiling hit, or "all-apps-down" unacceptable |
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
Run/Fly/Knative) is the highest-leverage scale step — it simultaneously restores
**scale-to-zero** (lost on the single box), provides **Firecracker-grade
isolation** (retiring the gVisor discussion), and removes the compute SPOF. And
because the Dockerfile is the contract, it's a re-point.
