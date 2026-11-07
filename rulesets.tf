# Layer 3 (spec 02b section 4 as revised, Amendment 3 item 4, Amendment 6 rule 2 and N-17; spec 02d Amendment A-4):
# two organization rulesets that keep ACSE Change inside the naming boundary {prefix}acse{suffix}/**.
#
# - acse-change-only-on-acse-branches: every branch except refs/heads/<boundary>/** ; creation, update, deletion
#   restricted, and force pushes blocked (A-4). The name is fixed (N-17) and is the one ACSE's served template uses.
#   Readiness requires the exclude list to equal refs/heads/<boundary>/** exactly (B.5-4), so a naming change
#   edits this one ruleset's exclusion in place.
# - acse-change-no-force-push: exactly refs/heads/<boundary>/** ; non_fast_forward only, so ACSE Change cannot
#   force-push its own branches. Deletion stays allowed: the deep test deletes {b}/connectivity-test. This is the
#   ruleset LR-6's force_push_blocked reads (core ruleset_layer.force_push_check: an active branch ruleset covering
#   the boundary, nothing excluded inside it, non_fast_forward, a readable bypass list without ACSE Change). DEC-12.
# - acse-change-no-tags: every tag; creation, update and deletion restricted (A-4).
#
# Bypass, for both: repository roles Write (4), Maintain (2) and Admin (5) -- GitHub's built-in role ids, as the
# served template names them -- plus the customer's own bots and, unless turned off, deploy keys. ACSE Change is never
# on either list (validation.tf refuses it).

locals {
  repository_role_bypass = [4, 2, 5] # write, maintain, admin

  ruleset_bypass = concat(
    [for id in local.repository_role_bypass : { actor_id = id, actor_type = "RepositoryRole" }],
    [for id in var.ruleset_bypass_integration_ids : { actor_id = id, actor_type = "Integration" }],
    var.ruleset_bypass_deploy_keys ? [{ actor_id = null, actor_type = "DeployKey" }] : [],
  )
}

resource "github_organization_ruleset" "branches" {
  name        = "acse-change-only-on-acse-branches"
  target      = "branch"
  enforcement = var.ruleset_enforcement

  conditions {
    ref_name {
      include = ["~ALL"]
      exclude = [local.boundary_ref]
    }
    repository_name {
      include = var.ruleset_repository_include
      exclude = var.ruleset_repository_exclude
    }
  }

  dynamic "bypass_actors" {
    for_each = local.ruleset_bypass
    content {
      actor_id    = bypass_actors.value.actor_id
      actor_type  = bypass_actors.value.actor_type
      bypass_mode = "always"
    }
  }

  rules {
    creation         = true
    update           = true
    deletion         = true
    non_fast_forward = true
  }

  depends_on = [terraform_data.tenant_config]
}

resource "github_organization_ruleset" "boundary_no_force_push" {
  name        = "acse-change-no-force-push"
  target      = "branch"
  enforcement = var.ruleset_enforcement

  conditions {
    ref_name {
      include = [local.boundary_ref]
      exclude = []
    }
    repository_name {
      include = var.ruleset_repository_include
      exclude = var.ruleset_repository_exclude
    }
  }

  dynamic "bypass_actors" {
    for_each = local.ruleset_bypass
    content {
      actor_id    = bypass_actors.value.actor_id
      actor_type  = bypass_actors.value.actor_type
      bypass_mode = "always"
    }
  }

  rules {
    non_fast_forward = true
  }

  depends_on = [terraform_data.tenant_config]
}

resource "github_organization_ruleset" "tags" {
  name        = "acse-change-no-tags"
  target      = "tag"
  enforcement = var.ruleset_enforcement

  conditions {
    ref_name {
      include = ["~ALL"]
      exclude = []
    }
    repository_name {
      include = var.ruleset_repository_include
      exclude = var.ruleset_repository_exclude
    }
  }

  dynamic "bypass_actors" {
    for_each = local.ruleset_bypass
    content {
      actor_id    = bypass_actors.value.actor_id
      actor_type  = bypass_actors.value.actor_type
      bypass_mode = "always"
    }
  }

  rules {
    creation = true
    update   = true
    deletion = true
  }

  depends_on = [terraform_data.tenant_config]
}
