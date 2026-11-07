#!/usr/bin/env python3
"""Static checks on template/.github/workflows/acse-setup-apply.yml (spec 02e AC-1, AC-4).

- No `secrets.` and no `vars.` anywhere: the template reads no repository secret or variable.
- `${{ }}` holds only GitHub's own context and the file's own env: no tenant value can enter by expression.
- Every `uses:` is pinned to a full commit SHA.
- Permissions are contents: read, plus id-token: write on the jobs (OIDC is the only cloud access).
- No literal that names a tenant: no AWS account id, no role ARN, no region.
- DEC-20, SC-1, SC-5 and the third round, structurally: exactly three jobs. `check` (pull_request, phase check, no
  environment, cloud-only -target plan, the GA-4 summary line); `plan` (push to the default branch, phase plan, no
  environment, never names acse-setup-apply, posts the plan); `apply` (needs plan, push to the default branch,
  environment acse-setup-apply, phase apply, refuses an unreviewed plan). Only apply uses the apply phase, which is
  the only phase whose root reads the setup App's key.

Prints the template's sha256 so a release can record it (the pinning format is open, docs/decisions.md DEC-12).
"""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "template" / ".github" / "workflows" / "acse-setup-apply.yml"

ALLOWED_EXPRESSIONS = {
    "github.sha",
    "runner.temp",
    "env.TERRAFORM_VERSION",
    "github.event_name == 'pull_request' && github.ref || 'default-branch'",
}


APPLY_ENVIRONMENT = "acse-setup-apply"


def pr_plan_targets() -> list:
    """The module's output pr_plan_targets, read from outputs.tf."""
    text = (ROOT / "outputs.tf").read_text(encoding="utf-8")
    block = text.split('output "pr_plan_targets"', 1)[1].split("]", 1)[0]
    return re.findall(r'"([a-z_]+\.[a-z_]+)"', block)


def _runs(job: dict) -> str:
    return "\n".join(str(step.get("run", "")) for step in job.get("steps") or [])


GA4_SUMMARY = "ACSE will comment if any listed repository isn't visible to ACSE Read."
DEFAULT_BRANCH_PUSH = ("github.event_name == 'push' && "
                       "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)")


def structure(doc: dict) -> list:
    """DEC-20, SC-1, SC-5 and the third round: three jobs, three roles; only apply reaches the setup App's key."""
    problems = []
    jobs = doc.get("jobs") or {}
    if set(jobs) != {"check", "plan", "apply"}:
        return [f"jobs must be exactly check, plan and apply, not {sorted(jobs)}"]
    check, plan, apply = jobs["check"], jobs["plan"], jobs["apply"]

    # check: pull requests, no environment, no GitHub credential, cloud side only.
    if not str(check.get("if", "")).startswith("github.event_name == 'pull_request' &&"):
        problems.append("check must run only on pull_request")
    if "environment" in check:
        problems.append("check must name no environment")
    if (check.get("env") or {}).get("TF_VAR_acse_setup_phase") != "check":
        problems.append("check must run with TF_VAR_acse_setup_phase: check")
    if re.search(r"terraform\s+apply", _runs(check)):
        problems.append("check must never run the apply command")
    targets = re.findall(r"-target=module\.acse_tenant\.(\S+)", _runs(check))
    if targets != pr_plan_targets():
        problems.append(f"check must target exactly the module's pr_plan_targets: {targets} vs {pr_plan_targets()}")
    if any(not t.startswith(("aws_", "terraform_data.")) for t in targets):
        problems.append("check targets must all be cloud-side (aws_*) or terraform_data")
    if GA4_SUMMARY not in _runs(check):
        problems.append(f"check's summary must say exactly: {GA4_SUMMARY}")

    # plan: default-branch pushes, no approval gate, read-only; cannot reach the apply environment or key.
    if str(plan.get("if", "")) != DEFAULT_BRANCH_PUSH:
        problems.append("plan must run only on a push to the default branch")
    if "environment" in plan:
        problems.append("plan must name no environment")
    if APPLY_ENVIRONMENT in yaml.safe_dump(plan):
        problems.append(f"plan must not reference {APPLY_ENVIRONMENT}")
    if (plan.get("env") or {}).get("TF_VAR_acse_setup_phase") != "plan":
        problems.append("plan must run with TF_VAR_acse_setup_phase: plan (its root reads the read-only App's key only)")
    if re.search(r"terraform\s+apply", _runs(plan)) or "-target" in _runs(plan):
        problems.append("plan must plan everything and never run the apply command")
    if "GITHUB_STEP_SUMMARY" not in _runs(plan):
        problems.append("plan must post the plan to the job summary")

    # apply: after plan, default-branch pushes, in the environment; the only phase that reads the setup App's key.
    needs = apply.get("needs")
    if needs != "plan" and not (isinstance(needs, list) and "plan" in needs):
        problems.append("apply must need plan")
    if str(apply.get("if", "")) != DEFAULT_BRANCH_PUSH:
        problems.append("apply must run only on a push to the default branch")
    environment = apply.get("environment")
    if isinstance(environment, dict):
        environment = environment.get("name")
    if environment != APPLY_ENVIRONMENT:
        problems.append(f"apply must run in the environment {APPLY_ENVIRONMENT}")
    if (apply.get("env") or {}).get("TF_VAR_acse_setup_phase") != "apply":
        problems.append("apply must run with TF_VAR_acse_setup_phase: apply")
    if "-target" in _runs(apply):
        problems.append("apply must plan everything: no -target")
    if "differs from the reviewed plan" not in _runs(apply):
        problems.append("apply must refuse a plan that differs from the reviewed one")

    # Only the apply job may use the apply phase.
    for name, job in (("check", check), ("plan", plan)):
        if "apply" == (job.get("env") or {}).get("TF_VAR_acse_setup_phase"):
            problems.append(f"{name} must not use the apply phase")
    return problems


def environment_settings() -> list:
    """SC-1: the module's apply environment has no administrator bypass, prevents self-review, requires reviewers and
    deploys from the default branch only. Read statically from setup.tf (the tests assert the planned values)."""
    text = (ROOT / "setup.tf").read_text(encoding="utf-8")
    block = text.split('resource "github_repository_environment" "setup_apply"', 1)[1].split("\n}\n", 1)[0]
    problems = []
    for pattern, why in ((r"\bcan_admins_bypass\s*=\s*false\b", "can_admins_bypass = false"),
                         (r"\bprevent_self_review\s*=\s*true\b", "prevent_self_review = true"),
                         (r"\bprotected_branches\s*=\s*false\b", "deployment from the default branch only (protected_branches = false)"),
                         (r"\bcustom_branch_policies\s*=\s*true\b", "custom_branch_policies = true"),
                         (r"\n  reviewers \{", "a static (non-optional) reviewers block")):
        if not re.search(pattern, block):
            problems.append(f"setup.tf: the apply environment must set {why}")
    if 'branch_pattern = local.setup_default' not in text:
        problems.append("setup.tf: the apply environment's deployment policy must be the default branch")
    return problems


def main() -> int:
    text = TEMPLATE.read_text(encoding="utf-8")
    problems = []
    for word in ("secrets.", "vars."):
        if word in text:
            problems.append(f"the template contains {word!r} (AC-1)")
    for expr in re.findall(r"\$\{\{\s*(.*?)\s*\}\}", text):
        if expr not in ALLOWED_EXPRESSIONS:
            problems.append(f"expression not allowed: ${{{{ {expr} }}}}")
    for ref in re.findall(r"^\s*-?\s*uses:\s*(\S+)", text, flags=re.M):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}", ref):
            problems.append(f"uses: not pinned to a commit SHA: {ref}")
    for perm in re.findall(r"^\s+([a-z-]+):\s*(read|write|none)\s*$", text, flags=re.M):
        if perm not in (("contents", "read"), ("id-token", "write")):
            problems.append(f"permission not allowed: {perm[0]}: {perm[1]}")
    if re.search(r"(?<![0-9])[0-9]{12}(?![0-9])", text):
        problems.append("a 12-digit number (an AWS account id?) appears in the template")
    if re.search(r"arn:aws", text):
        problems.append("an ARN appears in the template")
    if re.search(r"\b[a-z]{2}-[a-z]+-[0-9]\b", text):
        problems.append("an AWS region appears in the template")
    problems += structure(yaml.safe_load(text))
    problems += environment_settings()
    if problems:
        for p in problems:
            print(f"acse-setup-apply.yml: {p}", file=sys.stderr)
        return 1
    print("acse-setup-apply.yml sha256:" + hashlib.sha256(TEMPLATE.read_bytes()).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
