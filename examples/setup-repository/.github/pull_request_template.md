<!-- Setup repository pull request (acse-setup-apply.yml). -->

## What changes in `config/tenant.yaml` or `terraform/`

<!-- One or two lines. Two approvals under CODEOWNERS are required to merge. -->

## Before you approve

- This pull request's check plans the **cloud side only**: it holds no GitHub credential. After merge, the **plan**
  job posts the full GitHub and cloud plan in its job summary. Approve the `acse-setup-apply` environment only after
  you have read that plan; the apply refuses to run anything else.
- **Gate repositories ACSE Read cannot see.** If ACSE may write to this repository (Direct tenants), ACSE comments on
  this pull request when a repository listed under `gate.registered_repositories` isn't visible to ACSE Read. The
  comment is updated in place and appears at ACSE's next sync, a few minutes after each push.
- **Outbox-only tenants:** ACSE does not write to your repositories, so it will not comment here. Check
  **Setup → Access** in the ACSE portal for visibility warnings before you approve.
