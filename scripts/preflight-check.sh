#!/usr/bin/env bash
# Read-only preflight check for this repo's deployment. Run it before the first deployment, before a
# demo, or whenever a workflow run fails. It checks everything that went wrong during the first rollout
# (see TROUBLESHOOTING.md):
#
#   Tools         aws, jq, curl
#   AWS           identity, state bucket (region, versioning), GitHub OIDC provider and role trust
#                 (ID-based subject), AZs, VPC/EIP quotas
#   Org           AWS Organization membership, guardrail simulation for the Databricks roles
#   Repo config   region consistency in live/ (when run from the repo root)
#   Databricks    service principal token, account admin, metastore in region, admin group and members,
#                 workspaces
#
# Usage (AWS CloudShell in US East (Ohio), or locally with AWS CLI v2, jq and curl):
#
#   bash scripts/preflight-check.sh
#
# Databricks checks use DATABRICKS_ACCOUNT_ID / DATABRICKS_CLIENT_ID / DATABRICKS_CLIENT_SECRET from the
# environment. If they're missing and the shell is interactive, it prompts (the secret isn't echoed).
# Set SKIP_DATABRICKS=true to check AWS only.
#
# Exit code: 0 if no FAIL, 1 otherwise. Nothing is created or changed.

set -uo pipefail

REGION="${REGION:-us-east-2}"
NAME_PREFIX="${NAME_PREFIX:-dbx-architect-lab}"
AVAILABILITY_ZONES="${AVAILABILITY_ZONES:-us-east-2a us-east-2b}"
ENVIRONMENTS="${ENVIRONMENTS:-dev uat prod}"
GH_ROLE_NAME="${GH_ROLE_NAME:-gh-dbx-platform-infra-aws}"
GH_SUB_PREFIX="${GH_SUB_PREFIX:-repo:DBxArchitectLab@336295900/dbx-platform-infra-aws@1404588117}"
ADMIN_GROUP="${ADMIN_GROUP:-DBX_Architect_Lab_Admin}"
# Users who should be able to open the workspaces (members of ADMIN_GROUP); space-separated.
ADMIN_USERS="${ADMIN_USERS:-dbxarchitectlab@gmail.com}"
SKIP_DATABRICKS="${SKIP_DATABRICKS:-false}"

DATABRICKS_AWS_ACCOUNT="414351767826"   # Databricks control plane (assumes the cross-account and UC roles)
DBX_ACCOUNTS_HOST="https://accounts.cloud.databricks.com"

# --- helpers ---------------------------------------------------------------------------------------

PASS=0; WARN=0; FAIL=0
section() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
pass()    { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn()    { WARN=$((WARN + 1)); printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail()    { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
hint()    { printf '        %s\n' "$*"; }

# --- tools -----------------------------------------------------------------------------------------

section "Tools"
for cmd in aws jq curl; do
  if command -v "$cmd" >/dev/null 2>&1; then pass "$cmd found"; else fail "$cmd not found"; fi
done
command -v aws >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo; echo "aws and jq are required; stopping."; exit 1; }

# --- AWS identity ----------------------------------------------------------------------------------

section "AWS identity"
if CALLER=$(aws sts get-caller-identity --output json 2>/dev/null); then
  ACCOUNT_ID=$(echo "$CALLER" | jq -r .Account)
  pass "account $ACCOUNT_ID as $(echo "$CALLER" | jq -r .Arn)"
else
  fail "no AWS credentials"
  hint "Sign in: CloudShell, 'aws sso login', or 'aws configure' (TROUBLESHOOTING.md section 1)"
  echo; echo "Cannot continue without AWS credentials."; exit 1
fi
STATE_BUCKET="${STATE_BUCKET:-${NAME_PREFIX}-tfstate-${ACCOUNT_ID}}"

# --- Terraform state bucket ------------------------------------------------------------------------

section "Terraform state bucket ($STATE_BUCKET)"
if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  LOCATION=$(aws s3api get-bucket-location --bucket "$STATE_BUCKET" --query LocationConstraint --output text)
  [ "$LOCATION" = "None" ] && LOCATION="us-east-1"
  if [ "$LOCATION" = "$REGION" ]; then pass "exists in $REGION"
  else fail "exists in $LOCATION, expected $REGION"; hint "Align live/root.hcl state_region (TROUBLESHOOTING.md section 3)"; fi
  VERSIONING=$(aws s3api get-bucket-versioning --bucket "$STATE_BUCKET" --query Status --output text 2>/dev/null)
  [ "$VERSIONING" = "Enabled" ] && pass "versioning enabled" || warn "versioning is '$VERSIONING' (recommended: Enabled)"
else
  fail "bucket not found"
  hint "Run: bash scripts/setup-aws-prerequisites.sh"
fi

# --- GitHub OIDC -----------------------------------------------------------------------------------

section "GitHub OIDC provider and role"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if PROVIDER=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" --output json 2>/dev/null); then
  if echo "$PROVIDER" | jq -e '.ClientIDList | index("sts.amazonaws.com")' >/dev/null; then
    pass "OIDC provider exists with audience sts.amazonaws.com"
  else
    fail "OIDC provider is missing audience sts.amazonaws.com"
  fi
else
  fail "OIDC provider not found"; hint "Run: bash scripts/setup-aws-prerequisites.sh"
fi

if ROLE=$(aws iam get-role --role-name "$GH_ROLE_NAME" --output json 2>/dev/null); then
  ROLE_ARN=$(echo "$ROLE" | jq -r .Role.Arn)
  pass "role $ROLE_ARN"
  hint "GitHub secret AWS_ROLE_ARN must equal this ARN in every environment"
  TRUST=$(echo "$ROLE" | jq -c .Role.AssumeRolePolicyDocument)
  echo "$TRUST" | jq -e --arg p "$OIDC_ARN" '[.Statement[].Principal.Federated] | index($p)' >/dev/null \
    && pass "trust policy federates the GitHub OIDC provider" \
    || fail "trust policy doesn't federate $OIDC_ARN"
  # Subjects may sit under StringEquals, StringLike or StringEqualsIgnoreCase.
  SUBJECTS=$(echo "$TRUST" | jq -r '[.Statement[].Condition // {} | to_entries[] | .value["token.actions.githubusercontent.com:sub"] // empty] | flatten | .[]')
  for e in $ENVIRONMENTS; do
    WANT="${GH_SUB_PREFIX}:environment:${e}"
    if echo "$SUBJECTS" | grep -qixF "$WANT"; then pass "trusts $WANT"
    else fail "trust policy is missing subject $WANT"; hint "Check the token's sub claim (TROUBLESHOOTING.md section 4)"; fi
  done
  aws iam list-attached-role-policies --role-name "$GH_ROLE_NAME" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null \
    | grep -q AdministratorAccess && pass "AdministratorAccess attached" \
    || warn "AdministratorAccess not attached; make sure the attached policies cover VPC, EC2, S3 and IAM"
else
  fail "role $GH_ROLE_NAME not found"; hint "Run: bash scripts/setup-aws-prerequisites.sh"
fi

# --- Network capacity ------------------------------------------------------------------------------

section "Region $REGION capacity"
for az in $AVAILABILITY_ZONES; do
  STATE=$(aws ec2 describe-availability-zones --region "$REGION" --zone-names "$az" \
            --query 'AvailabilityZones[0].State' --output text 2>/dev/null)
  [ "$STATE" = "available" ] && pass "AZ $az available" || fail "AZ $az not available in $REGION (state: ${STATE:-unknown})"
done

quota_check() { # <label> <service> <quota-code> <used>
  local label=$1 service=$2 code=$3 used=$4 limit
  limit=$(aws service-quotas get-service-quota --region "$REGION" --service-code "$service" --quota-code "$code" \
            --query 'Quota.Value' --output text 2>/dev/null | cut -d. -f1)
  if [ -z "$limit" ] || [ "$limit" = "None" ]; then warn "$label: $used in use (quota not readable)"; return; fi
  local need; need=$(echo "$ENVIRONMENTS" | wc -w)
  if [ "$used" -ge "$limit" ]; then warn "$label: $used used of $limit (at the limit; new environments will fail)"
  elif [ $((used + need)) -gt "$limit" ]; then warn "$label: $used used of $limit; up to $need more may be needed (fine if some environments are already deployed)"
  else pass "$label: $used used of $limit"; fi
}
VPCS=$(aws ec2 describe-vpcs --region "$REGION" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)
EIPS=$(aws ec2 describe-addresses --region "$REGION" --query 'length(Addresses)' --output text 2>/dev/null || echo 0)
quota_check "VPCs"         vpc L-F678F1CE "$VPCS"
quota_check "Elastic IPs"  ec2 L-0263D0A3 "$EIPS"

DEPLOYED=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=vpc-${NAME_PREFIX}-*" \
             --query 'Vpcs[].Tags[?Key==`Name`]|[].Value' --output text 2>/dev/null)
[ -n "$DEPLOYED" ] && hint "Deployed VPCs: $DEPLOYED"

# --- AWS Organization guardrails -------------------------------------------------------------------

section "AWS Organization guardrails"
if ORG=$(aws organizations describe-organization --output json 2>/dev/null); then
  warn "member of organization $(echo "$ORG" | jq -r .Organization.Id) (management account $(echo "$ORG" | jq -r .Organization.MasterAccountId))"
  hint "Org RCPs that deny sts:*/s3:* to outside principals block Databricks ($DATABRICKS_AWS_ACCOUNT)."
  hint "This can't be checked from a member account; see TROUBLESHOOTING.md 7.5-7.6 (management account)."
else
  pass "not in an AWS Organization"
fi

# Databricks roles created by Terraform: simulate EC2 in the deployment region (shows SCP effects).
DBX_ROLES=$(aws iam list-roles --query "Roles[?starts_with(RoleName,'${NAME_PREFIX}-') && ends_with(RoleName,'-crossaccount')].Arn" \
              --output text 2>/dev/null)
if [ -z "$DBX_ROLES" ]; then
  hint "No ${NAME_PREFIX}-*-crossaccount roles yet (created by the workspace stack); skipping simulation."
else
  for arn in $DBX_ROLES; do
    RESULT=$(aws iam simulate-principal-policy --policy-source-arn "$arn" \
      --action-names ec2:RunInstances ec2:DescribeVpcs ec2:CreateTags \
      --context-entries "ContextKeyName=aws:RequestedRegion,ContextKeyValues=$REGION,ContextKeyType=string" \
      --output json 2>/dev/null)
    if [ -z "$RESULT" ]; then warn "could not simulate ${arn##*/}"; continue; fi
    DENIED=$(echo "$RESULT" | jq -r '[.EvaluationResults[] | select(.EvalDecision != "allowed") | "\(.EvalActionName)=\(.EvalDecision)"] | join(", ")')
    ORG_DENIED=$(echo "$RESULT" | jq -r '[.EvaluationResults[] | select(.OrganizationsDecisionDetail.AllowedByOrganizations == false) | .EvalActionName] | join(", ")')
    if [ -z "$DENIED" ]; then pass "${arn##*/}: EC2 allowed in $REGION"
    else fail "${arn##*/}: $DENIED"; [ -n "$ORG_DENIED" ] && hint "Denied by org SCP: $ORG_DENIED (TROUBLESHOOTING.md section 7)"; fi
    TRUST_PRINCIPAL=$(aws iam get-role --role-name "${arn##*/}" --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.AWS' --output text 2>/dev/null)
    [ "$TRUST_PRINCIPAL" = "arn:aws:iam::${DATABRICKS_AWS_ACCOUNT}:root" ] \
      && pass "${arn##*/}: trusts Databricks ($DATABRICKS_AWS_ACCOUNT)" \
      || fail "${arn##*/}: trust principal is '$TRUST_PRINCIPAL'"
  done
fi

# --- Repo configuration ----------------------------------------------------------------------------

section "Repo configuration"
if [ -f live/root.hcl ]; then
  STATE_REGION=$(sed -n 's/^[[:space:]]*state_region[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' live/root.hcl)
  [ "$STATE_REGION" = "$REGION" ] && pass "live/root.hcl state_region = $REGION" \
    || fail "live/root.hcl state_region = '$STATE_REGION', expected $REGION"
  for f in live/*/config.yaml; do
    [ -f "$f" ] || continue
    R=$(sed -n 's/^[[:space:]]*region:[[:space:]]*"\{0,1\}\([a-z0-9-]*\)"\{0,1\}.*/\1/p' "$f" | head -1)
    [ "$R" = "$REGION" ] && pass "$f region = $R" || fail "$f region = '$R', expected $REGION"
  done
  for env in $ENVIRONMENTS; do
    f="live/$env/config.yaml"; [ -f "$f" ] || continue
    PL=$(sed -n '/^private_link:/,/^[^[:space:]]/s/^[[:space:]]*enabled:[[:space:]]*\([a-z]*\).*/\1/p' "$f" | head -1)
    [ "$PL" = "true" ] && warn "$f private_link.enabled = true (needs the Databricks Enterprise tier; TROUBLESHOOTING.md section 6)" \
      || pass "$f private_link.enabled = ${PL:-false}"
  done
  STALE=$(grep -rln "us-east-1" live --include=*.hcl --include=*.yaml 2>/dev/null | tr '\n' ' ')
  [ -z "$STALE" ] && pass "no us-east-1 leftovers in live/" || warn "us-east-1 still referenced in: $STALE"
else
  hint "Not run from the repo root; skipping config checks."
fi

# --- Databricks ------------------------------------------------------------------------------------

section "Databricks account"
if [ "$SKIP_DATABRICKS" = "true" ]; then
  hint "SKIP_DATABRICKS=true; skipping."
else
  if [ -t 0 ]; then
    [ -n "${DATABRICKS_ACCOUNT_ID:-}" ]    || read -rp  "  Databricks account ID (empty to skip): " DATABRICKS_ACCOUNT_ID
    if [ -n "${DATABRICKS_ACCOUNT_ID:-}" ]; then
      [ -n "${DATABRICKS_CLIENT_ID:-}" ]     || read -rp  "  Service principal client ID: " DATABRICKS_CLIENT_ID
      [ -n "${DATABRICKS_CLIENT_SECRET:-}" ] || { read -rsp "  Service principal client secret: " DATABRICKS_CLIENT_SECRET; echo; }
    fi
  fi

  if [ -z "${DATABRICKS_ACCOUNT_ID:-}" ] || [ -z "${DATABRICKS_CLIENT_ID:-}" ] || [ -z "${DATABRICKS_CLIENT_SECRET:-}" ]; then
    warn "Databricks credentials not provided; skipping Databricks checks"
  else
    ACC="$DBX_ACCOUNTS_HOST/api/2.0/accounts/$DATABRICKS_ACCOUNT_ID"
    TOKEN_RESP=$(curl -s -u "$DATABRICKS_CLIENT_ID:$DATABRICKS_CLIENT_SECRET" \
      -d "grant_type=client_credentials&scope=all-apis" \
      "$DBX_ACCOUNTS_HOST/oidc/accounts/$DATABRICKS_ACCOUNT_ID/v1/token")
    TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token // empty' 2>/dev/null)
    unset DATABRICKS_CLIENT_SECRET

    if [ -z "$TOKEN" ]; then
      fail "OAuth token request failed: $(echo "$TOKEN_RESP" | jq -r '.error_description // .error // .' 2>/dev/null | head -c 200)"
      hint "Check account ID, client ID and secret; regenerate the secret if expired (TROUBLESHOOTING.md section 5)"
    else
      pass "service principal OAuth token issued"
      api() { curl -s -H "Authorization: Bearer $TOKEN" "$@"; }

      # Metastores (also proves account admin)
      MS=$(api "$ACC/metastores")
      if echo "$MS" | jq -e '.error_code' >/dev/null 2>&1; then
        fail "listing metastores: $(echo "$MS" | jq -r '"\(.error_code) \(.message)"')"
        hint "Service principal needs the Account admin role"
      else
        pass "service principal is account admin"
        REGION_MS=$(echo "$MS" | jq -r --arg r "$REGION" '[.metastores[]? | select(.region == $r)][0] // empty | "\(.metastore_id) \(.name)"')
        if [ -z "$REGION_MS" ]; then
          pass "no metastore in $REGION yet (the metastore stack will create it)"
        elif [ -n "${DATABRICKS_METASTORE_ID:-}" ] && [ "${REGION_MS%% *}" = "$DATABRICKS_METASTORE_ID" ]; then
          pass "metastore in $REGION matches DATABRICKS_METASTORE_ID (${REGION_MS#* })"
        else
          warn "metastore already in $REGION: $REGION_MS"
          hint "DATABRICKS_METASTORE_ID (GitHub secret) must be ${REGION_MS%% *}; don't apply the metastore stack again if it isn't managed by it"
        fi
      fi

      # Admin group, its members, the SP and admin users
      GROUP=$(api -G --data-urlencode "filter=displayName eq \"$ADMIN_GROUP\"" "$ACC/scim/v2/Groups")
      GROUP_ID=$(echo "$GROUP" | jq -r '.Resources[0].id // empty')
      if [ -z "$GROUP_ID" ]; then
        fail "group $ADMIN_GROUP not found"; hint "Create it in the account console (User management -> Groups)"
      else
        pass "group $ADMIN_GROUP exists"
        MEMBERS=$(api "$ACC/scim/v2/Groups/$GROUP_ID" | jq -r '[.members[]?.value] | join(" ")')
        SP_ID=$(api -G --data-urlencode "filter=applicationId eq \"$DATABRICKS_CLIENT_ID\"" "$ACC/scim/v2/ServicePrincipals" \
                  | jq -r '.Resources[0].id // empty')
        [[ " $MEMBERS " == *" $SP_ID "* ]] && [ -n "$SP_ID" ] && pass "service principal is in $ADMIN_GROUP" \
          || fail "service principal is not in $ADMIN_GROUP"
        for u in $ADMIN_USERS; do
          UID_=$(api -G --data-urlencode "filter=userName eq \"$u\"" "$ACC/scim/v2/Users" | jq -r '.Resources[0].id // empty')
          if [ -z "$UID_" ]; then warn "user $u doesn't exist in the account (needed for grants and workspace access)"
          elif [[ " $MEMBERS " == *" $UID_ "* ]]; then pass "user $u is in $ADMIN_GROUP"
          else warn "user $u is not in $ADMIN_GROUP, so it can't open the workspaces (TROUBLESHOOTING.md section 8)"; fi
        done
      fi

      # Workspaces
      WS=$(api "$ACC/workspaces")
      if echo "$WS" | jq -e 'type == "array"' >/dev/null 2>&1; then
        for env in $ENVIRONMENTS; do
          W=$(echo "$WS" | jq -c --arg n "dbw-${NAME_PREFIX}-${env}" '.[] | select(.workspace_name == $n)')
          if [ -z "$W" ]; then
            hint "workspace dbw-${NAME_PREFIX}-${env}: not deployed yet"
          else
            STATUS=$(echo "$W" | jq -r .workspace_status)
            URL="https://$(echo "$W" | jq -r .deployment_name).cloud.databricks.com"
            [ "$STATUS" = "RUNNING" ] && pass "workspace dbw-${NAME_PREFIX}-${env}: RUNNING  $URL" \
              || warn "workspace dbw-${NAME_PREFIX}-${env}: $STATUS  $URL"
            if [ -n "${GROUP_ID:-}" ]; then
              ASSIGNED=$(api "$ACC/workspaces/$(echo "$W" | jq -r .workspace_id)/permissionassignments" \
                | jq -r --arg g "$ADMIN_GROUP" '[.permission_assignments[]? | select(.principal.group_name == $g or .principal.display_name == $g) | .permissions[]] | join(",")')
              [[ "$ASSIGNED" == *ADMIN* ]] && pass "  $ADMIN_GROUP has ADMIN on ${env}" \
                || fail "  $ADMIN_GROUP has no ADMIN assignment on ${env} (re-apply the ${env} workspace stack)"
            fi
          fi
        done
      else
        warn "could not list workspaces"
      fi
    fi
  fi
fi

# --- summary ---------------------------------------------------------------------------------------

printf '\n\033[1m== Summary: %d passed, %d warnings, %d failed\033[0m\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo "See TROUBLESHOOTING.md for each failure."; exit 1; }
exit 0
