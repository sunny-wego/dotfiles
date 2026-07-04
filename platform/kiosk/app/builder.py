"""The build-verify-heal loop + Trivy scan + registry push.

This is the loop the README calls the product. Flow per attempt:

    generate/heal Dockerfile
        -> enforce base-image allowlist        (structural guard)
        -> docker build                        (build)
        -> boot the image and probe the port   (verify — catches runtime crashes,
                                                 not just build failures)
    on any failure -> feed the captured output back to the LLM and retry,
    capped by max iterations AND a shared token budget.

On success: Trivy scan (informational at M1 — logged, not blocking) then push to
the registry, honoring the deploy-from-image contract.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx

from . import baseimages, dockercli
from .config import config
from .detect import Detection
from .llm import LLMSession, LLMError, TokenBudgetExceeded


@dataclass
class BuildOutcome:
    ok: bool
    image: str = ""
    port: int = 8080
    dockerfile: str = ""
    attempts: int = 0
    reason: str = ""
    logs: list[str] = field(default_factory=list)


class Builder:
    def __init__(self, slug: str, project_root: str, detection: Detection,
                 llm: LLMSession, log) -> None:
        self.slug = slug
        self.root = project_root
        self.detection = detection
        self.llm = llm
        self.log = log
        self.image = f"{config.REGISTRY_HOST}/tenant-{slug}:{int(time.time())}"
        self.port = detection.suggested_port

    def run(self, *, manifests: dict[str, str], tree: str) -> BuildOutcome:
        outcome = BuildOutcome(ok=False, image=self.image, port=self.port)
        try:
            dockerfile = self.llm.generate_dockerfile(
                detection_summary=self.detection.summary(),
                tree=tree,
                manifests=manifests,
            )
        except (LLMError, TokenBudgetExceeded) as e:
            outcome.reason = f"generation failed: {e}"
            return outcome

        max_iter = config.HEAL_MAX_ITERATIONS
        for attempt in range(1, max_iter + 1):
            outcome.attempts = attempt
            outcome.dockerfile = dockerfile
            self.log(f"── attempt {attempt}/{max_iter} ──")

            ok, why = baseimages.validate(dockerfile)
            if not ok:
                self.log(f"[allowlist] rejected: {why}")
                err = f"Base image rejected by allowlist: {why}. Use an allowlisted family."
                dockerfile = self._heal_or_stop(dockerfile, err, outcome)
                if dockerfile is None:
                    return outcome
                continue

            # Test affordance: poison attempt 1 so heal must recover later.
            df_built = dockerfile
            if config.INDUCE_BUILD_FAILURE and attempt == 1:
                self.log("[induce] poisoning first build to exercise the heal loop")
                df_built = dockerfile + "\nRUN echo 'induced failure' >&2 && exit 7\n"

            build_err = self._build(df_built)
            if build_err is not None:
                dockerfile = self._heal_or_stop(df_built, build_err, outcome)
                if dockerfile is None:
                    return outcome
                continue

            verify_err = self._verify()
            if verify_err is not None:
                dockerfile = self._heal_or_stop(dockerfile, verify_err, outcome)
                if dockerfile is None:
                    return outcome
                continue

            # Build + verify passed.
            self._trivy_scan()
            # Push mirrors the image to the registry (deploy-from-image
            # contract), but is best-effort: on a single box the local daemon
            # already holds the built tag, so a registry that isn't configured
            # as insecure must not fail an otherwise-good provision.
            pushed = self._push()
            outcome.ok = True
            outcome.reason = ("built, verified and pushed" if pushed
                              else "built and verified (registry push skipped)")
            outcome.dockerfile = dockerfile
            return outcome

        outcome.reason = f"heal loop exhausted after {max_iter} attempts"
        return outcome

    # ── steps ──────────────────────────────────────────────────────────────
    def _build(self, dockerfile: str) -> str | None:
        Path(self.root, "Dockerfile").write_text(dockerfile, encoding="utf-8")
        self.log("[build] docker build …")
        res = dockercli.build(self.image, self.root)
        if res.ok:
            self.log("[build] ok")
            return None
        self.log("[build] FAILED")
        return res.out

    def _verify(self) -> str | None:
        """Boot the image on the internal backplane and probe the port.

        Catches the crash-on-start class of failure (bad CMD, missing runtime
        dep, wrong port) that a build alone won't surface."""
        name = f"verify-{self.slug}"
        dockercli.rm_force(name)
        self.log(f"[verify] booting on :{self.port} …")
        res = dockercli.run([
            "run", "-d", "--name", name,
            "--network", "platform_backplane",
            "-e", f"PORT={self.port}",
            self.image,
        ], timeout=60)
        if not res.ok:
            return f"container failed to start:\n{res.out}"

        deadline = time.time() + config.VERIFY_TIMEOUT_S
        last = ""
        try:
            while time.time() < deadline:
                # Container died? Grab logs and heal.
                st = dockercli.run(
                    ["inspect", "-f", "{{.State.Running}}", name], timeout=15)
                if st.ok and st.out.strip() == "false":
                    return f"container exited during boot:\n{dockercli.logs(name)}"
                try:
                    r = httpx.get(f"http://{name}:{self.port}/", timeout=3)
                    self.log(f"[verify] app responded HTTP {r.status_code}")
                    return None  # any HTTP response = it's listening
                except httpx.HTTPError as e:
                    last = str(e)
                time.sleep(2)
            return (f"app did not accept connections on :{self.port} within "
                    f"{config.VERIFY_TIMEOUT_S}s (last: {last})\n{dockercli.logs(name)}")
        finally:
            dockercli.rm_force(name)

    def _trivy_scan(self) -> None:
        # Trivy is installed in the kiosk image; scan the built image directly.
        # M1: informational only — surfaced in the build log, not blocking.
        self.log("[trivy] scanning image …")
        res = _trivy(self.image)
        tail = "\n".join(res.out.strip().splitlines()[-15:])
        self.log(f"[trivy] {tail or 'no high/critical findings'}")

    def _push(self) -> bool:
        self.log("[push] pushing to registry …")
        res = dockercli.run(["push", self.image], timeout=600)
        if res.ok:
            self.log("[push] ok")
            return True
        self.log("[push] skipped — registry not reachable/insecure; "
                 "deploying the locally-built image instead")
        return False

    def _heal_or_stop(self, dockerfile: str, error_log: str,
                      outcome: BuildOutcome) -> str | None:
        self.log("[heal] asking the model to fix the failure …")
        try:
            fixed = self.llm.heal_dockerfile(previous=dockerfile, error_log=error_log)
            self.log(f"[heal] new Dockerfile proposed "
                     f"({self.llm.tokens_used}/{self.llm.budget} tokens used)")
            return fixed
        except TokenBudgetExceeded as e:
            outcome.reason = f"token budget exhausted: {e}"
        except LLMError as e:
            outcome.reason = f"heal failed: {e}"
        return None


def _trivy(image: str):
    import subprocess
    try:
        proc = subprocess.run(
            ["trivy", "image", "--quiet", "--scanners", "vuln",
             "--severity", "HIGH,CRITICAL", image],
            capture_output=True, text=True, timeout=300,
        )
        return dockercli.Run(proc.returncode, (proc.stdout or "") + (proc.stderr or ""))
    except Exception as e:  # noqa: BLE001
        return dockercli.Run(1, f"trivy unavailable: {e}")
