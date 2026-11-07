#!/usr/bin/env bash
# acse-tenant, SaaS mode: write-only publication into InitValue's namespace (spec 02e Amendment 6 section A, SA-1).
# Called by saas.tf's provisioners, only on apply. It signs in as the publish role and only that role, and makes only
# the calls that role allows: ssm PutParameter and DeleteParameter, secretsmanager PutSecretValue. It reads nothing,
# and it never prints a value.
#
#   saas-publish.sh settings   ACSE_INDEX_NAME, ACSE_INDEX_VALUE, ACSE_PART_COUNT, ACSE_PART_<i>: parts first, index last
#   saas-publish.sh delete     ACSE_PARAMETER_NAME: delete one parameter; one already gone is not an error
#   saas-publish.sh app-keys   ACSE_{READ,CHANGE}_SECRET_NAME, ACSE_{READ,CHANGE}_APP_KEY: put a new version of each
#                              key that is given
#
# Always: ACSE_REGION, ACSE_PUBLISH_ROLE_ARN. Needs bash, curl, python3 and the AWS CLI v2 (GitHub's hosted runners
# have all four).
#
# Sign-in. In GitHub Actions it takes a fresh OIDC token for audience sts.amazonaws.com (the job has id-token: write),
# else the file AWS_WEB_IDENTITY_TOKEN_FILE names, and assumes ACSE_PUBLISH_ROLE_ARN with it. Every other credential
# in the environment (the job's own AWS role, profiles, the credentials file) is cleared for these calls, so a write
# can never land with the customer's own identity, and the role's trust (the apply job's SC-1 subject) decides.

set -euo pipefail

action="${1:?usage: saas-publish.sh settings|delete|app-keys}"
: "${ACSE_REGION:?}" "${ACSE_PUBLISH_ROLE_ARN:?}"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

token_file="$work/web-identity-token"
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" \
    | python3 -I -c 'import json, sys; open(sys.argv[1], "w").write(json.load(sys.stdin)["value"])' "$token_file"
elif [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ] && [ -r "${AWS_WEB_IDENTITY_TOKEN_FILE}" ]; then
  cp "$AWS_WEB_IDENTITY_TOKEN_FILE" "$token_file"
else
  echo "acse-tenant: no GitHub OIDC token to assume the SaaS publish role with. The role trusts only acse-setup-apply.yml's apply job. For a one-time bootstrap apply run elsewhere, set saas_publish_on_apply = false." >&2
  exit 1
fi

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE \
  AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
export AWS_ROLE_ARN="$ACSE_PUBLISH_ROLE_ARN" AWS_WEB_IDENTITY_TOKEN_FILE="$token_file" AWS_ROLE_SESSION_NAME="acse-saas-publish"
export AWS_REGION="$ACSE_REGION" AWS_DEFAULT_REGION="$ACSE_REGION" AWS_PAGER=""

put_parameter() { # name value
  printf '%s' "$2" > "$work/value"
  aws ssm put-parameter --name "$1" --type String --data-type text --tier Advanced --overwrite \
    --value "file://$work/value" > /dev/null
  rm -f "$work/value"
}

case "$action" in
  settings)
    : "${ACSE_INDEX_NAME:?}" "${ACSE_INDEX_VALUE:?}" "${ACSE_PART_COUNT:?}"
    for ((i = 0; i < ACSE_PART_COUNT; i++)); do
      part="ACSE_PART_$i"
      put_parameter "$ACSE_INDEX_NAME/$i" "${!part:?part $i is missing}"
    done
    put_parameter "$ACSE_INDEX_NAME" "$ACSE_INDEX_VALUE"
    echo "acse-tenant: published $ACSE_INDEX_NAME ($ACSE_PART_COUNT parts)"
    ;;
  delete)
    : "${ACSE_PARAMETER_NAME:?}"
    if out="$(aws ssm delete-parameter --name "$ACSE_PARAMETER_NAME" 2>&1)"; then
      echo "acse-tenant: deleted $ACSE_PARAMETER_NAME"
    elif grep -q "ParameterNotFound" <<< "$out"; then
      echo "acse-tenant: $ACSE_PARAMETER_NAME was already absent"
    else
      echo "$out" >&2
      exit 1
    fi
    ;;
  app-keys)
    : "${ACSE_READ_SECRET_NAME:?}" "${ACSE_CHANGE_SECRET_NAME:?}"
    pushed=0
    for which in READ CHANGE; do
      key_var="ACSE_${which}_APP_KEY"
      name_var="ACSE_${which}_SECRET_NAME"
      if [ -n "${!key_var:-}" ]; then
        printf '%s' "${!key_var}" > "$work/secret"
        aws secretsmanager put-secret-value --secret-id "${!name_var}" --secret-string "file://$work/secret" > /dev/null
        rm -f "$work/secret"
        pushed=$((pushed + 1))
        echo "acse-tenant: put a new version of ${!name_var}"
      fi
    done
    if [ "$pushed" -eq 0 ]; then
      echo "acse-tenant: saas_app_keys_version changed but neither saas_read_app_private_key nor saas_change_app_private_key was given" >&2
      exit 1
    fi
    ;;
  *)
    echo "acse-tenant: unknown action $action" >&2
    exit 2
    ;;
esac
