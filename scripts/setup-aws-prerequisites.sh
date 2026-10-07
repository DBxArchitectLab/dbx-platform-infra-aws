#!/usr/bin/env bash
# Creates (or repairs) the AWS prerequisites this repo needs, in the account you're signed in to:
#   1. S3 bucket for Terraform state   (dbx-architect-lab-tfstate-<account-id>, versioned, private, encrypted)
#   2. GitHub Actions OIDC identity provider
#   3. IAM role GitHub Actions assumes (trusts this repo's dev/uat/prod GitHub environments)
#
# Idempotent: re-running only creates what's missing and refreshes the role's trust policy.
# Run in AWS CloudShell (region US East (Ohio)) or anywhere with the AWS CLI v2 and jq:
#
#   bash scripts/setup-aws-prerequisites.sh
#   DRY_RUN=true bash scripts/setup-aws-prerequisites.sh     # show what would change, change nothing
#
# Defaults match live/root.hcl and DEPLOYMENT.md; override any of them with environment variables.
# See TROUBLESHOOTING.md sections 2-4 for the issues this script prevents.

set -uo pipefail

REGION="${REGION:-us-east-2}"
NAME_PREFIX="${NAME_PREFIX:-dbx-architect-lab}"
GH_ROLE_NAME="${GH_ROLE_NAME:-gh-dbx-platform-infra-aws}"
# Must equal the `sub` claim GitHub puts in the OIDC token, minus ":environment:<env>". This org uses the
# ID-based format (repo:<org>@<org-id>/<repo>@<repo-id>); for the classic format use repo:<org>/<repo>.
GH_SUB_PREFIX="${GH_SUB_PREFIX:-repo:DBxArchitectLab@336295900/dbx-platform-infra-aws@1404588117}"
GH_ENVIRONMENTS="${GH_ENVIRONMENTS:-dev uat prod}"
# AdministratorAccess keeps a lab simple; set to false and attach a scoped policy yourself for production.
ATTACH_ADMIN_POLICY="${ATTACH_ADMIN_POLICY:-true}"
DRY_RUN="${DRY_RUN:-false}"

OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_AUDIENCE="sts.amazonaws.com"
ADMIN_POLICY_ARN="arn:aws:iam::aws:policy/AdministratorAccess"

# --- helpers ---------------------------------------------------------------------------------------

info()    { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()      { printf '  \033[32mOK\033[0m       %s\n' "$*"; }
created() { printf '  \033[33mCREATED\033[0m  %s\n' "$*"; }
updated() { printf '  \033[33mUPDATED\033[0m  %s\n' "$*"; }
planned() { printf '  \033[36mWOULD\033[0m    %s\n' "$*"; }
die()     { printf '  \033[31mERROR\033[0m    %s\n' "$*" >&2; exit 1; }

# step <label> <done-message> <command...>
# Runs a mutating AWS call and reports it, or only reports it in dry-run mode. Exits on failure.
step() {
  local label=$1 msg=$2; shift 2
  if [ "$DRY_RUN" = "true" ]; then
    planned "$msg"
    return 0
  fi
  if "$@" >/dev/null; then
    case $label in
      created) created "$msg" ;;
      updated) updated "$msg" ;;
      *)       ok "$msg" ;;
    esac
  else
    die "$msg failed"
  fi
}

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required (AWS CloudShell has both)."
done

# --- identity --------------------------------------------------------------------------------------

info "Identity"
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) || die "No AWS credentials. Sign in (CloudShell, aws sso login, or aws configure)."
ACCOUNT_ID=$(echo "$CALLER" | jq -r .Account)
ok "Account $ACCOUNT_ID as $(echo "$CALLER" | jq -r .Arn)"
ok "Region $REGION"
[ "$DRY_RUN" = "true" ] && ok "DRY_RUN=true: nothing will be changed"

STATE_BUCKET="${STATE_BUCKET:-${NAME_PREFIX}-tfstate-${ACCOUNT_ID}}"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# --- 1. Terraform state bucket ---------------------------------------------------------------------

info "Terraform state bucket: $STATE_BUCKET"
if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  LOCATION=$(aws s3api get-bucket-location --bucket "$STATE_BUCKET" --query LocationConstraint --output text)
  [ "$LOCATION" = "None" ] && LOCATION="us-east-1"
  if [ "$LOCATION" != "$REGION" ]; then
    die "Bucket exists in $LOCATION, not $REGION. Set state_region in live/root.hcl to $LOCATION, or use another bucket (TROUBLESHOOTING.md section 3)."
  fi
  ok "exists in $LOCATION"
else
  # us-east-1 is the only region that rejects a LocationConstraint.
  LOCATION_ARGS=()
  [ "$REGION" = "us-east-1" ] || LOCATION_ARGS=(--create-bucket-configuration "LocationConstraint=$REGION")
  step created "bucket in $REGION (if this fails, the name may be taken: set STATE_BUCKET)" \
    aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" "${LOCATION_ARGS[@]}"
  BUCKET_IS_NEW=true
fi

if [ "$DRY_RUN" = "true" ] && [ "${BUCKET_IS_NEW:-false}" = "true" ]; then
  planned "enable versioning, block public access, SSE-S3 encryption"
else
  step ok "versioning enabled" \
    aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
  step ok "public access blocked" \
    aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  step ok "SSE-S3 encryption" \
    aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
fi

# --- 2. GitHub OIDC provider -----------------------------------------------------------------------

info "GitHub OIDC provider"
if PROVIDER=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" --output json 2>/dev/null); then
  if echo "$PROVIDER" | jq -e --arg a "$OIDC_AUDIENCE" '.ClientIDList | index($a)' >/dev/null; then
    ok "exists with audience $OIDC_AUDIENCE"
  else
    step updated "add audience $OIDC_AUDIENCE" \
      aws iam add-client-id-to-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" --client-id "$OIDC_AUDIENCE"
  fi
else
  step created "$OIDC_ARN" \
    aws iam create-open-id-connect-provider --url "$OIDC_URL" --client-id-list "$OIDC_AUDIENCE"
fi

# --- 3. GitHub Actions role ------------------------------------------------------------------------

info "GitHub Actions role: $GH_ROLE_NAME"
SUBS=$(for e in $GH_ENVIRONMENTS; do echo "${GH_SUB_PREFIX}:environment:${e}"; done | jq -R . | jq -sc .)
TRUST_FILE=$(mktemp)
trap 'rm -f "$TRUST_FILE"' EXIT
jq -n --arg oidc "$OIDC_ARN" --arg aud "$OIDC_AUDIENCE" --argjson subs "$SUBS" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: { Federated: $oidc },
    Action: "sts:AssumeRoleWithWebIdentity",
    Condition: {
      StringEquals: {
        "token.actions.githubusercontent.com:aud": $aud,
        "token.actions.githubusercontent.com:sub": $subs
      }
    }
  }]
}' > "$TRUST_FILE"

if aws iam get-role --role-name "$GH_ROLE_NAME" >/dev/null 2>&1; then
  step ok "role exists (trust policy refreshed)" \
    aws iam update-assume-role-policy --role-name "$GH_ROLE_NAME" --policy-document "file://$TRUST_FILE"
else
  step created "role (if this fails, an org guardrail may block IAM changes)" \
    aws iam create-role --role-name "$GH_ROLE_NAME" --assume-role-policy-document "file://$TRUST_FILE" \
    --max-session-duration 7200 --description "GitHub Actions deploy role for dbx-platform-infra-aws"
fi

if [ "$ATTACH_ADMIN_POLICY" = "true" ]; then
  if aws iam list-attached-role-policies --role-name "$GH_ROLE_NAME" --output json 2>/dev/null \
       | jq -e --arg p "$ADMIN_POLICY_ARN" '.AttachedPolicies | map(.PolicyArn) | index($p)' >/dev/null; then
    ok "AdministratorAccess attached"
  else
    step updated "attach AdministratorAccess" \
      aws iam attach-role-policy --role-name "$GH_ROLE_NAME" --policy-arn "$ADMIN_POLICY_ARN"
  fi
else
  ok "ATTACH_ADMIN_POLICY=false: attach your own scoped policy"
fi

echo "  Trusted subjects:"
echo "$SUBS" | jq -r '.[] | "    - \(.)"'

# --- organization notice ---------------------------------------------------------------------------

info "AWS Organization"
if ORG=$(aws organizations describe-organization --output json 2>/dev/null); then
  echo "  This account is a member of organization $(echo "$ORG" | jq -r .Organization.Id) (management account $(echo "$ORG" | jq -r .Organization.MasterAccountId))."
  echo "  Its SCPs/RCPs can block Databricks (AWS account 414351767826) from assuming roles in this account."
  echo "  Run scripts/preflight-check.sh after the first workspace apply, and see TROUBLESHOOTING.md section 7."
else
  ok "not in an AWS Organization (no org guardrails apply)"
fi

# --- summary ---------------------------------------------------------------------------------------

info "Next steps"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${GH_ROLE_NAME}"
echo "  1. Set GitHub secret AWS_ROLE_ARN = $ROLE_ARN"
echo "     in each environment: $GH_ENVIRONMENTS"
echo "  2. Make sure live/root.hcl uses state_region = \"$REGION\" (state bucket: $STATE_BUCKET)"
echo "  3. Run: bash scripts/preflight-check.sh"
