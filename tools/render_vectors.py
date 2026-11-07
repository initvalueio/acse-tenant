#!/usr/bin/env python3
"""Render vectors/acse-tenant-vectors-1.0.json from vectors/cases/*/tenant.yaml, independently of the Terraform.

This is the second implementation of the module's naming and rendering rules. tests/*.tftest.hcl hold the module's
outputs equal to what this script writes, so the two must agree, and every other lane (the promoter, the runtime's
drift check, the control plane's Setup copy) can pin the vectors instead of reading the HCL.

    python3 -I tools/render_vectors.py          # rewrite the vectors file
    python3 -I tools/render_vectors.py --check  # exit 1 if it is stale

Needs PyYAML. Values are synthetic.
"""

from __future__ import annotations

import hashlib
import json
import math
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASES = ROOT / "vectors" / "cases"
OUT = ROOT / "vectors" / "acse-tenant-vectors-1.0.json"

INLINE_MAX = 8192  # settings-index-1.0: inline when the whole index document fits
PART_MAX = 7168    # bytes per part; parts are cut by characters, 7168 (ASCII) or 1792 (otherwise)
SECTIONS = ["approvals", "cloud", "code_sources", "delivery", "gate", "github", "naming", "outbox", "repositories"]
OIDC_HOST = "token.actions.githubusercontent.com"

# Module inputs per case, beyond tenant.yaml (the tests pass the same values).
CASE_INPUTS = {
    "outbox-and-gate": {
        "setup_commit": "566a44a3b3bcd2b692af3477a4bd1d05ae1872ac",
        "outbox_default_branch": "main",
        "policies_default_branch": "main",
        "outbox_oidc_subject_includes_job_workflow_ref": False,
        "kms_key_arn": None,
        "setup_credential_secret_arn": "arn:aws:secretsmanager:ca-central-1:111122223333:secret:platform/github/acse-setup-app/private-key-AbCdEf",
        "setup_plan_credential_secret_arn": "arn:aws:secretsmanager:ca-central-1:111122223333:secret:platform/github/acse-setup-plan-app/private-key-MnOpQr",
        "setup_credential_extra_reader_arns": ["arn:aws:iam::111122223333:role/platform-break-glass"],
        "setup_default_branch": "main",
        "setup_oidc_subject_repo": None,
        "outbox_oidc_subject_repo": None,
        "setup_apply_environment_reviewers": {"users": [], "teams": [1234567]},
    },
    "direct-minimal": {
        "setup_commit": "0123456789abcdef0123456789abcdef01234567",
        "outbox_default_branch": None,
        "policies_default_branch": "main",
        "outbox_oidc_subject_includes_job_workflow_ref": False,
        "kms_key_arn": None,
        "setup_credential_secret_arn": None,
    },
    "large-split": {
        "setup_commit": "fedcba9876543210fedcba9876543210fedcba98",
        "outbox_default_branch": None,
        "policies_default_branch": "main",
        "outbox_oidc_subject_includes_job_workflow_ref": False,
        "kms_key_arn": None,
        "setup_credential_secret_arn": None,
    },
    "outbox-prefixed-boundary": {
        "setup_commit": "89abcdef0123456789abcdef0123456789abcdef",
        "outbox_default_branch": "trunk",
        "policies_default_branch": "main",
        "outbox_oidc_subject_includes_job_workflow_ref": True,
        "kms_key_arn": "arn:aws:kms:eu-west-1:444455556666:key/0f0e0d0c-0b0a-0908-0706-050403020100",
        "setup_credential_secret_arn": "arn:aws:secretsmanager:eu-west-1:444455556666:secret:globex/acse-setup-app-key-MnOpQr",
        "setup_plan_credential_secret_arn": "arn:aws:secretsmanager:eu-west-1:444455556666:secret:globex/acse-setup-plan-app-key-StUvWx",
        "setup_credential_extra_reader_arns": [],
        "setup_default_branch": "trunk",
        "setup_oidc_subject_repo": "globex@9000001/platform-acse-setup@9000002",
        "outbox_oidc_subject_repo": "globex@9000001/platform-acse-outbox@9000003",
        "setup_apply_environment_reviewers": {"users": [7000001], "teams": []},
    },
}

WHY = {
    "outbox-and-gate": "Outbox and Direct, gate audience set: every secret, nine inline settings indexes, both generated "
                       "files, and both setup roles with the job_workflow_ref subject and a read-only check App (DEC-20).",
    "direct-minimal": "Direct only, no naming, gate or outbox section: no promoter secret, no role, no generated file; "
                      "settings/naming is still published, as {}.",
    "large-split": "500 gate entries and 300 delivery overrides: settings/gate and settings/delivery are indexes "
                   "with parts; every other section is inline (DEC-6).",
    "outbox-prefixed-boundary": "Outbox only, boundary corp-acse-prod, a role under a path, the job_workflow_ref subject, "
                                "GitHub's immutable subject format (owner@id/name@id) for the setup and outbox repositories "
                                "and a customer-managed key; a gate list without an audience generates no gate file; "
                                "'&' in a setting is escaped as \\u0026.",
}


def tf_jsonencode(value) -> str:
    """Terraform's jsonencode: keys sorted, no whitespace, UTF-8 kept, and <, >, &, U+2028, U+2029 escaped."""
    text = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    for raw, escaped in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), (" ", "\\u2028"), (" ", "\\u2029")):
        text = text.replace(raw, escaped)
    return text


def gate_file(payload: dict, generated_from: dict) -> str:
    j = tf_jsonencode
    return (
        "{\n"
        f'  "gate_config_format_version": {j(payload["gate_config_format_version"])},\n'
        f'  "tenant": {j(payload["tenant"])},\n'
        f'  "audience": {j(payload["audience"])},\n'
        f'  "report_url": {j(payload["report_url"])},\n'
        '  "generated_from": {\n'
        f'    "repository": {j(generated_from["repository"])},\n'
        f'    "commit": {j(generated_from["commit"])},\n'
        f'    "tenant_yaml_sha256": {j(generated_from["tenant_yaml_sha256"])}\n'
        "  }\n"
        "}\n"
    )


def promoter_file(payload: dict, generated_from: dict) -> str:
    j = tf_jsonencode
    cloud = payload["cloud"]
    return (
        "{\n"
        f'  "promoter_config_format_version": {j(payload["promoter_config_format_version"])},\n'
        f'  "tenant": {j(payload["tenant"])},\n'
        '  "cloud": {\n'
        f'    "provider": {j(cloud["provider"])},\n'
        f'    "region": {j(cloud["region"])},\n'
        f'    "workflow_role": {j(cloud["workflow_role"])},\n'
        f'    "namespace": {j(cloud["namespace"])}\n'
        "  },\n"
        '  "generated_from": {\n'
        f'    "repository": {j(generated_from["repository"])},\n'
        f'    "commit": {j(generated_from["commit"])},\n'
        f'    "tenant_yaml_sha256": {j(generated_from["tenant_yaml_sha256"])}\n'
        "  }\n"
        "}\n"
    )


def render_case(name: str) -> dict:
    path = CASES / name / "tenant.yaml"
    raw = path.read_bytes()
    config = yaml.safe_load(raw)
    inputs = CASE_INPUTS[name]
    tenant = config["tenant"]
    cloud = config["cloud"]
    account, region, namespace = str(cloud["account"]), cloud["region"], cloud["namespace"]
    repos = config["repositories"]
    has_outbox = repos.get("outbox") is not None
    naming = config.get("naming", {})
    boundary = f'{naming.get("prefix", "")}acse{naming.get("suffix", "")}'
    sha = "sha256:" + hashlib.sha256(raw).hexdigest()

    secret_paths = ["evidence/seal-key/current", "evidence/seal-key/next", "github/change/private-key",
                    "github/read/private-key", "tfc/token"] + (["outbox/promoter/private-key"] if has_outbox else [])
    secret_names = {p: f"{namespace}/{p}" for p in sorted(secret_paths)}

    values = {s: config[s] for s in SECTIONS if s in config}
    values["naming"] = naming
    values = dict(sorted(values.items()))
    settings = {s: tf_jsonencode(v) for s, v in values.items()}
    settings_names = {s: f"/{namespace}/settings/{s}" for s in settings}
    arn_prefix = f"arn:aws:ssm:{region}:{account}:parameter/{namespace}"
    index, parts = {}, {}
    for section, payload in settings.items():
        nbytes = len(payload.encode("utf-8"))
        head = {"schema": "settings-index-1.0", "section": section, "commit": inputs["setup_commit"],
                "sha256": "sha256:" + hashlib.sha256(payload.encode("utf-8")).hexdigest(), "bytes": nbytes}
        inline = tf_jsonencode({**head, "parts": 0, "inline": values[section]})
        if len(inline.encode("utf-8")) <= INLINE_MAX:
            index[section] = inline
            continue
        chars = PART_MAX if nbytes == len(payload) else PART_MAX // 4
        count = math.ceil(len(payload) / chars)
        index[section] = tf_jsonencode({**head, "parts": count})
        for i in range(count):
            parts[f"{section}/{i}"] = payload[i * chars:(i + 1) * chars]

    expected: dict = {
        "tenant_yaml_sha256": sha,
        "namespace": namespace,
        "boundary": boundary,
        "branch_ruleset_exclude": f"refs/heads/{boundary}/**",
        "force_push_ruleset_include": [f"refs/heads/{boundary}/**"],
        "secret_names": secret_names,
        "settings_parameter_names": settings_names,
        "settings_payloads": settings,
        "settings_index_values": index,
        "settings_part_names": {k: f"/{namespace}/settings/{k}" for k in sorted(parts)},
        "settings_part_values": dict(sorted(parts.items())),
        "evidence_public_key_parameter_name": f"/{namespace}/evidence/public-key",
        "parameter_arn_prefix": arn_prefix,
    }

    if has_outbox:
        role = cloud["workflow_role"]
        rest = role.split(":role/", 1)[1].split("/")
        branch = inputs["outbox_default_branch"]
        outbox = repos["outbox"]
        workflow_ref = f"{outbox}/.github/workflows/acse-promote.yml@refs/heads/{branch}"
        subject = f"repo:{inputs.get('outbox_oidc_subject_repo') or outbox}:ref:refs/heads/{branch}"
        if inputs["outbox_oidc_subject_includes_job_workflow_ref"]:
            subject += f":job_workflow_ref:{workflow_ref}"
        statements = [
            {"Action": "ssm:GetParameters", "Effect": "Allow", "Sid": "ReadThePromotersThreeParameters",
             "Resource": [f"{arn_prefix}/settings/outbox", f"{arn_prefix}/settings/naming",
                          f"{arn_prefix}/evidence/public-key"]},
            {"Action": "secretsmanager:GetSecretValue", "Effect": "Allow", "Sid": "ReadThePromotersAppKey",
             "Resource": f"arn:aws:secretsmanager:{region}:{account}:secret:{namespace}/outbox/promoter/private-key-??????"},
        ]
        if inputs["kms_key_arn"]:
            statements.append({"Action": "kms:Decrypt", "Effect": "Allow",
                               "Sid": "DecryptThePromotersAppKeyThroughSecretsManagerOnly",
                               "Resource": inputs["kms_key_arn"],
                               "Condition": {"StringEquals": {"kms:ViaService": f"secretsmanager.{region}.amazonaws.com"}}})
        expected["promoter"] = {
            "role_arn": role,
            "role_name": rest[-1],
            "role_path": "/" + "".join(part + "/" for part in rest[:-1]),
            "trust_subject": subject,
            "trust_policy": {
                "Version": "2012-10-17",
                "Statement": [{
                    "Sid": "AcsePromoteOnTheOutboxDefaultBranchOnly",
                    "Effect": "Allow",
                    "Principal": {"Federated": f"arn:aws:iam::{account}:oidc-provider/{OIDC_HOST}"},
                    "Action": "sts:AssumeRoleWithWebIdentity",
                    "Condition": {"StringEquals": {f"{OIDC_HOST}:aud": "sts.amazonaws.com", f"{OIDC_HOST}:sub": subject}},
                }],
            },
            "read_policy_statements": statements,
            "store_reads": {
                "parameters": [f"/{namespace}/settings/outbox", f"/{namespace}/settings/naming",
                               f"/{namespace}/evidence/public-key"],
                "secret": f"{namespace}/outbox/promoter/private-key",
            },
        }
    else:
        expected["promoter"] = None

    if inputs.get("setup_credential_secret_arn"):
        setup = repos["setup"]
        branch = inputs["setup_default_branch"]
        workflow = f"{setup}/.github/workflows/acse-setup-apply.yml"
        apply_arn = f"arn:aws:iam::{account}:role/acse-setup-apply"
        check_arn = f"arn:aws:iam::{account}:role/acse-setup-check"
        plan_arn = f"arn:aws:iam::{account}:role/acse-setup-plan"
        segment = inputs.get("setup_oidc_subject_repo") or setup
        apply_sub = f"repo:{segment}:environment:acse-setup-apply:job_workflow_ref:{workflow}@refs/heads/{branch}"
        check_sub = f"repo:{segment}:pull_request:job_workflow_ref:{workflow}@refs/pull/*/merge"
        plan_sub = f"repo:{segment}:ref:refs/heads/{branch}:job_workflow_ref:{workflow}@refs/heads/{branch}"
        provider = f"arn:aws:iam::{account}:oidc-provider/{OIDC_HOST}"

        def secret_policy(reader, word, extra=True):
            return {"Version": "2012-10-17", "Statement": [
                {"Sid": f"OnlyThe{word}RoleReadsThisKey", "Effect": "Deny", "Principal": "*",
                 "Action": "secretsmanager:GetSecretValue", "Resource": "*",
                 "Condition": {"StringNotEquals": {"aws:PrincipalArn": [reader] + (inputs["setup_credential_extra_reader_arns"] if extra else [])}}},
                {"Sid": f"The{word}RoleReadsThisKey", "Effect": "Allow", "Principal": {"AWS": reader},
                 "Action": "secretsmanager:GetSecretValue", "Resource": "*"}]}

        expected["setup_roles"] = {
            "apply_role_arn": apply_arn,
            "apply_subject": apply_sub,
            "apply_environment": "acse-setup-apply",
            "plan_role_arn": plan_arn,
            "plan_subject": plan_sub,
            "plan_trust_policy": {"Version": "2012-10-17", "Statement": [{
                "Sid": "AcseSetupPostMergePlanJobOnly", "Effect": "Allow", "Principal": {"Federated": provider},
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {"StringEquals": {f"{OIDC_HOST}:aud": "sts.amazonaws.com", f"{OIDC_HOST}:sub": plan_sub}}}]},
            "plan_secret_policy": secret_policy(plan_arn, "PostMergePlan", extra=False),
            "check_role_arn": check_arn,
            "check_subject": check_sub,
            "apply_trust_policy": {"Version": "2012-10-17", "Statement": [{
                "Sid": "AcseSetupApplyJobOnly", "Effect": "Allow", "Principal": {"Federated": provider},
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {"StringEquals": {f"{OIDC_HOST}:aud": "sts.amazonaws.com", f"{OIDC_HOST}:sub": apply_sub}}}]},
            "check_trust_policy": {"Version": "2012-10-17", "Statement": [{
                "Sid": "AcseSetupPullRequestCheckOnly", "Effect": "Allow", "Principal": {"Federated": provider},
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {"StringEquals": {f"{OIDC_HOST}:aud": "sts.amazonaws.com"},
                              "StringLike": {f"{OIDC_HOST}:sub": check_sub}}}]},
            "credential_policy": secret_policy(apply_arn, "SetupApply"),
        }
    else:
        expected["setup_roles"] = None

    generated_from = {"repository": repos["setup"], "commit": inputs["setup_commit"], "tenant_yaml_sha256": sha}
    files: dict = {}
    gate = config.get("gate", {})
    if gate.get("audience") and gate.get("report_url"):
        payload = {"gate_config_format_version": "1.0", "tenant": tenant, "audience": gate["audience"],
                   "report_url": gate["report_url"]}
        files["gate"] = {"repository": repos["policies"], "branch": inputs["policies_default_branch"],
                         "path": ".github/acse-gate.json", "schema": "gate-config-1.0",
                         "content": gate_file(payload, generated_from),
                         "pull_request_branch": "setup-apply/acse-gate-config-" + hashlib.sha256(tf_jsonencode(payload).encode()).hexdigest()[:12]}
    if has_outbox:
        payload = {"promoter_config_format_version": "1.0", "tenant": tenant,
                   "cloud": {"provider": cloud["provider"], "region": region, "workflow_role": cloud["workflow_role"],
                             "namespace": namespace}}
        files["promoter"] = {"repository": repos["outbox"], "branch": inputs["outbox_default_branch"],
                             "path": ".github/acse-promote.json", "schema": "promoter-config-1.0",
                             "content": promoter_file(payload, generated_from),
                             "pull_request_branch": "setup-apply/acse-promote-config-" + hashlib.sha256(tf_jsonencode(payload).encode()).hexdigest()[:12]}
    expected["generated_files"] = files

    return {"name": name, "why": WHY[name], "tenant_yaml_path": f"vectors/cases/{name}/tenant.yaml",
            "tenant_yaml": raw.decode("utf-8"), "module_inputs": inputs, "expected": expected}


STATIC = {
    "secrets": [
        {"path": "github/read/private-key", "when": "always", "value_written_by": "customer's pipeline",
         "read_by": ["ACSE runtime (IAM)"]},
        {"path": "github/change/private-key", "when": "always", "value_written_by": "customer's pipeline",
         "read_by": ["ACSE runtime (IAM)"]},
        {"path": "outbox/promoter/private-key", "when": "repositories.outbox is set", "value_written_by": "customer's pipeline",
         "read_by": ["acse-promote.yml via cloud.workflow_role (OIDC)"]},
        {"path": "evidence/seal-key/current", "when": "always", "value_written_by": "keygen", "read_by": ["ACSE runtime (IAM)"]},
        {"path": "evidence/seal-key/next", "when": "always", "value_written_by": "keygen", "read_by": ["ACSE runtime (IAM)"]},
        {"path": "tfc/token", "when": "always", "value_written_by": "customer's pipeline", "read_by": ["ACSE runtime (IAM)"]},
    ],
    "secret_rules": {
        "service": "AWS Secrets Manager",
        "name": "acse/<tenant>/<path> (no leading slash)",
        "arn": "arn:aws:secretsmanager:<region>:<account>:secret:acse/<tenant>/<path>-<6 random characters>",
        "created_by": "acse-tenant: the secret container only. No version is ever written or read by Terraform; a "
                      "secret with no version is the placeholder (reported missing until the value is put in).",
        "kms": "kms_key_arn when set, else the AWS-managed aws/secretsmanager key",
    },
    "parameters": [
        {"path": "settings/<section>", "sections": SECTIONS,
         "when": "the section is present in tenant.yaml; settings/naming always ({} when naming is absent)",
         "written_by": "acse-tenant (the setup apply) only, index last", "read_by": ["ACSE runtime", "promoter (outbox, naming; always inline)", "gate (ruleset mode, deferred)"],
         "value": "always a settings-index-1.0 document (DEC-6): jsonencode of {schema, section, commit, sha256, bytes, "
                  "parts, inline}, keys sorted; inline (parts 0) when that document is <= 8192 bytes, else parts n and no "
                  "inline. payload = the tenant.yaml section exactly as written (not normalised), as Terraform jsonencode "
                  "renders it: keys sorted, no whitespace, '<' '>' '&' escaped as \\u003c \\u003e \\u0026; sha256 and "
                  "bytes are over the payload's UTF-8 bytes; commit is the setup commit applied"},
        {"path": "settings/<section>/<i>", "when": "parts > 0; i = 0..parts-1, decimal, unpadded",
         "written_by": "acse-tenant, before the index; stale parts destroyed after it",
         "value": "the payload's i-th slice, at most 7168 bytes, cut by characters (7168 per part for an ASCII payload, "
                  "1792 otherwise), so no UTF-8 sequence is split; readers concatenate in order and check bytes and sha256"},
        {"path": "evidence/public-key", "when": "created and written by keygen", "written_by": "keygen only; acse-tenant "
         "neither creates nor writes it", "read_by": ["promoter", "customer (to pin)", "workflows"],
         "value": "{key_id, public_key_pem, sha256, next:{key_id, public_key_pem, sha256}} (keygen's shape)"},
    ],
    "parameter_rules": {
        "service": "AWS Systems Manager Parameter Store",
        "name": "/acse/<tenant>/<path> (leading slash: SSM requires one for a name that contains '/')",
        "arn": "arn:aws:ssm:<region>:<account>:parameter/acse/<tenant>/<path> (no slash after 'parameter')",
        "type": "String, data_type text, tier Advanced (8 KB) for every index and part; more than 64 parts refuses to plan",
    },
    "setup_roles": {
        "when": "setup_credential_secret_arn is set (DEC-20)",
        "subject_template": "the setup repository's OIDC subject template is always include_claim_keys [repo, context, job_workflow_ref] (SC-1); <segment> is setup_oidc_subject_repo, owner/name or owner@id/name@id (immutable format)",
        "apply": {"name": "acse-setup-apply (setup_apply_role_name)",
                  "sub": "repo:<segment>:environment:acse-setup-apply:job_workflow_ref:<setup>/.github/workflows/acse-setup-apply.yml@refs/heads/<default branch>",
                  "operator": "StringEquals",
                  "reads": "the setup credential secret (customer-named, outside acse/<tenant>/); its resource policy denies GetSecretValue to every other principal but setup_credential_extra_reader_arns",
                  "policies": "setup_apply_policy_arns (default AdministratorAccess)"},
        "plan": {"name": "acse-setup-plan (setup_plan_role_name)",
                 "sub": "repo:<segment>:ref:refs/heads/<default branch>:job_workflow_ref:<setup>/.github/workflows/acse-setup-apply.yml@refs/heads/<default branch>",
                 "operator": "StringEquals (push-only is the template's job condition: AWS cannot match event_name)",
                 "reads": "only the read-only App's key (setup_plan_credential_secret_arn, customer-named, outside acse/<tenant>/); its resource policy denies every other principal",
                 "policies": "setup_plan_policy_arns (default ReadOnlyAccess)"},
        "check": {"name": "acse-setup-check (setup_check_role_name)",
                  "sub": "repo:<segment>:pull_request:job_workflow_ref:<setup>/.github/workflows/acse-setup-apply.yml@refs/pull/*/merge",
                  "operator": "StringLike (the pull request number only; must be tested on a real organization, fails closed)",
                  "reads": "never the setup credential, and no GitHub credential at all (SC-5): the pull request plans the cloud side only",
                  "policies": "setup_check_policy_arns (default ReadOnlyAccess)"},
        "environment": "acse-setup-apply in the setup repository: deployable from the default branch only, can_admins_bypass false, prevent_self_review true, at least one required reviewer",
    },
    "promoter_role": {
        "sub_repo_segment": "outbox_oidc_subject_repo: owner/name or owner@id/name@id (immutable format)",
        "when": "repositories.outbox is set and manage_promoter_role is true",
        "arn": "cloud.workflow_role exactly (its account must be cloud.account)",
        "trust": {"principal": f"arn:aws:iam::<account>:oidc-provider/{OIDC_HOST}", "aud": "sts.amazonaws.com",
                  "sub_default": "repo:<outbox owner/name>:ref:refs/heads/<outbox default branch>",
                  "sub_with_job_workflow_ref": "repo:<outbox>:ref:refs/heads/<branch>:job_workflow_ref:<outbox>/.github/workflows/acse-promote.yml@refs/heads/<branch>",
                  "operator": "StringEquals"},
        "grants": ["ssm:GetParameters on settings/outbox, settings/naming, evidence/public-key",
                   "secretsmanager:GetSecretValue on outbox/promoter/private-key",
                   "kms:Decrypt on kms_key_arn with kms:ViaService secretsmanager.<region>.amazonaws.com, only when kms_key_arn is set"],
        "max_session_duration": 3600,
    },
    "rulesets": [
        {"name": "acse-change-only-on-acse-branches", "level": "organization", "target": "branch",
         "ref_name": {"include": ["~ALL"], "exclude": ["refs/heads/<boundary>/**"]},
         "repository_name": {"include": ["~ALL"], "exclude": []},
         "rules": ["creation", "update", "deletion", "non_fast_forward"],
         "bypass_actors": "RepositoryRole 4 (write), 2 (maintain), 5 (admin); Integration per ruleset_bypass_integration_ids; DeployKey unless ruleset_bypass_deploy_keys is false; all bypass_mode always; never ACSE Change",
         "enforcement": "evaluate by default (ruleset_enforcement)"},
        {"name": "acse-change-no-force-push", "level": "organization", "target": "branch",
         "ref_name": {"include": ["refs/heads/<boundary>/**"], "exclude": []},
         "repository_name": {"include": ["~ALL"], "exclude": []},
         "rules": ["non_fast_forward"],
         "not_restricted": "deletion (the deep test deletes {b}/connectivity-test), creation, update",
         "bypass_actors": "the same list as the branch ruleset; never ACSE Change",
         "enforcement": "the same as the branch ruleset; LR-6's force_push_blocked passes only when active",
         "decided": "lead, 2026-11-07 (DEC-12)"},
        {"name": "acse-change-no-tags", "level": "organization", "target": "tag",
         "ref_name": {"include": ["~ALL"], "exclude": []},
         "repository_name": {"include": ["~ALL"], "exclude": []},
         "rules": ["creation", "update", "deletion"],
         "bypass_actors": "the same list as the branch ruleset",
         "enforcement": "the same as the branch ruleset"},
    ],
    "generated_files": [
        {"key": "gate", "repository": "repositories.policies", "path": ".github/acse-gate.json", "schema": "gate-config-1.0",
         "when": "gate.audience and gate.report_url are both set",
         "members": "gate_config_format_version, tenant, audience, report_url, generated_from{repository, commit, tenant_yaml_sha256}"},
        {"key": "promoter", "repository": "repositories.outbox", "path": ".github/acse-promote.json", "schema": "promoter-config-1.0",
         "when": "repositories.outbox is set",
         "members": "promoter_config_format_version, tenant, cloud{provider, region, workflow_role, namespace}, generated_from{repository, commit, tenant_yaml_sha256}"},
    ],
    "generated_file_rules": {
        "bytes": "two-space indent, members in schema order, values as Terraform jsonencode renders them, one trailing line feed",
        "generated_from": "repository = repositories.setup; commit = the setup commit at which the rest of the file last "
                          "changed (latched; not rewritten when only the commit changes); tenant_yaml_sha256 = sha256 over "
                          "the bytes of config/tenant.yaml at that commit",
        "compared": "with generated_from excluded, as the runtime's drift check compares",
        "pull_request_branch": "setup-apply/acse-gate-config-<12 hex> or setup-apply/acse-promote-config-<12 hex>: the "
                               "first 12 hex of sha256 over the payload (the file without generated_from) as jsonencode renders it",
    },
}


def render() -> str:
    names = sorted(p.name for p in CASES.iterdir() if (p / "tenant.yaml").is_file())
    doc = {
        "acse_tenant_vectors_version": "1.0",
        "description": "Governed vectors of the acse-tenant module (spec 02e sections 3 and 4, Amendments 2 to 4; ledger "
                       "02e sections 10.2a, 10.3, 10.10 and 11.0b). Every store path the module creates or grants, and the "
                       "shape and exact bytes of every file it generates, for each case's tenant.yaml. Produced by "
                       "tools/render_vectors.py; tests/*.tftest.hcl hold the module equal to it. Synthetic values.",
        "store": {k: STATIC[k] for k in ("secret_rules", "secrets", "parameter_rules", "parameters")},
        "promoter_role": STATIC["promoter_role"],
        "setup_roles": STATIC["setup_roles"],
        "rulesets": STATIC["rulesets"],
        "generated_file_rules": STATIC["generated_file_rules"],
        "generated_files": STATIC["generated_files"],
        "cases": [render_case(n) for n in names],
    }
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    text = render()
    if "--check" in sys.argv[1:]:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            print(f"{OUT.relative_to(ROOT)} is stale: run python3 -I tools/render_vectors.py", file=sys.stderr)
            return 1
        return 0
    OUT.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
