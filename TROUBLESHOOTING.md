# Troubleshooting runbook

The problems hit while deploying this repo for the first time (dev, uat and prod on Databricks on AWS), and how
each one was diagnosed and fixed. Every check is a copy-paste script. For the setup steps themselves, see
[DEPLOYMENT.md](DEPLOYMENT.md).

**Where scripts run**

| Label | Where |
| --- | --- |
| 🟦 **Member CloudShell** | AWS console signed in to the **workload account** (where the workspaces live), region **US East (Ohio) `us-east-2`**, CloudShell icon `>_` |
| 🟥 **Management CloudShell** | AWS console signed in to the AWS Organization's **management account**. Only needed for org guardrails (section 7). |
| ⬛ **GitHub Actions** | `.github/workflows/terragrunt-deploy.yml` run log |

Scripts never contain secrets. They look up IDs with `aws sts get-caller-identity`, or prompt with `read -sp`.

---

## Contents

- [Overview: what went wrong and why](#overview-what-went-wrong-and-why)
- [0. Quick health check (demo starting point)](#0-quick-health-check-demo-starting-point)
- [1. AWS console: which account am I in?](#1-aws-console-which-account-am-i-in)
- [2. AWS bootstrap: state bucket, OIDC provider, GitHub role](#2-aws-bootstrap-state-bucket-oidc-provider-github-role)
- [3. Region mismatch: state bucket in Ohio, repo in N. Virginia](#3-region-mismatch-state-bucket-in-ohio-repo-in-n-virginia)
- [4. GitHub → AWS: `Not authorized to perform sts:AssumeRoleWithWebIdentity`](#4-github--aws-not-authorized-to-perform-stsassumerolewithwebidentity)
- [5. Databricks service principal checks](#5-databricks-service-principal-checks)
- [6. `ENTERPRISE` pricing tier required (PrivateLink)](#6-enterprise-pricing-tier-required-privatelink)
- [7. `Failed credential validation checks` (org guardrails)](#7-failed-credential-validation-checks-org-guardrails)
- [8. Can't open the workspace: admin group membership](#8-cant-open-the-workspace-admin-group-membership)
- [9. Dev catalog visible in the uat workspace](#9-dev-catalog-visible-in-the-uat-workspace)
- [10. Cost hygiene while troubleshooting](#10-cost-hygiene-while-troubleshooting)
- [Lessons learned](#lessons-learned)

---

## Overview: what went wrong and why

| # | Symptom | Root cause | Fix | Section |
| --- | --- | --- | --- | --- |
| 1 | Root sign-in: *"sign-in as root is currently disabled for this account"* | The account belongs to an AWS Organization that centrally removed member-account root credentials | Use the federated `AccountFullAccessRole`; reach the org's management account through multi-session | [1](#1-aws-console-which-account-am-i-in) |
| 2 | State bucket created in Ohio, repo configured for `us-east-1` | The console defaulted to Ohio; the repo was written for N. Virginia | Switch the whole repo to `us-east-2` (configs, AZs, PrivateLink service names) | [3](#3-region-mismatch-state-bucket-in-ohio-repo-in-n-virginia) |
| 3 | `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity` | The GitHub org uses the **ID-based** OIDC subject (`repo:Org@id/repo@id:environment:env`), but the trust policy expected `repo:Org/repo:environment:env` | Print the token's `sub` claim, then rewrite the trust policy to match it | [4](#4-github--aws-not-authorized-to-perform-stsassumerolewithwebidentity) |
| 4 | `does not have one of required pricing tier(s) ENTERPRISE` | Back-end PrivateLink needs the Databricks Enterprise tier; the account is Premium | `private_link.enabled: false`; clusters go out through the NAT gateway | [6](#6-enterprise-pricing-tier-required-privatelink) |
| 5 | `cannot create mws credentials: Failed credential validation checks` | The org's **RCP** denies `sts:*`/`s3:*` to principals outside the org, so Databricks (AWS account `414351767826`) can't assume the cross-account role | Exempt `414351767826` in the RCP (management account) | [7](#7-failed-credential-validation-checks-org-guardrails) |
| 6 | Workspace created but the user can't open it | The user wasn't in `DBX_Architect_Lab_Admin`, which is the group granted workspace ADMIN | Add the user to the group with an account SCIM API call | [8](#8-cant-open-the-workspace-admin-group-membership) |
| 7 | `dbxarchitectlab_dev` shows up in the uat workspace | Catalogs are metastore-level and visible in every attached workspace by default | Bootstrap marks the catalog, external location and credential `ISOLATED` and binds each to its own workspace | [9](#9-dev-catalog-visible-in-the-uat-workspace) |

---

## 0. Quick health check (demo starting point)

**Automated:** run `bash scripts/preflight-check.sh` from the repo root (🟦 Member CloudShell). It covers most of
this runbook in one read-only pass:
- the AWS identity, state bucket, OIDC provider and role trust (section 4);
- AZs and quotas;
- the org guardrail simulation for the Databricks roles (section 7);
- the repo config's region and PrivateLink settings (sections 3 and 6);
- on the Databricks side: the service principal, account admin, metastore, admin group and members, workspaces and
  ADMIN assignments (sections 5 and 8).

It ends with a PASS/WARN/FAIL summary and exits 1 on any failure. `scripts/setup-aws-prerequisites.sh` fixes the
AWS-side failures (section 2).

**Manual:** a read-only check of everything AWS-side this deployment depends on:

```bash
REGION=us-east-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID   Caller: $(aws sts get-caller-identity --query Arn --output text)"

echo "== State bucket"
aws s3api get-bucket-location --bucket "dbx-architect-lab-tfstate-$ACCOUNT_ID" --output text 2>&1 | sed 's/^/  region: /'

echo "== GitHub OIDC provider"
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" \
  --query ClientIDList --output text 2>&1 | sed 's/^/  audiences: /'

echo "== GitHub deploy role"
aws iam get-role --role-name gh-dbx-platform-infra-aws --query Role.Arn --output text 2>&1 | sed 's/^/  /'

echo "== Databricks cross-account roles"
aws iam list-roles --query "Roles[?starts_with(RoleName,'dbx-architect-lab-')].RoleName" --output text | tr '\t' '\n' | sed 's/^/  /'

echo "== VPCs and NAT gateways"
aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=vpc-dbx-architect-lab-*" \
  --query 'Vpcs[].[Tags[?Key==`Name`]|[0].Value,VpcId,CidrBlock]' --output text | sed 's/^/  /'
aws ec2 describe-nat-gateways --region $REGION --filter "Name=state,Values=available" \
  --query 'NatGateways[].[NatGatewayId,VpcId,State]' --output text | sed 's/^/  NAT /'

echo "== Buckets"
aws s3api list-buckets --query "Buckets[?starts_with(Name,'dbx-architect-lab-')].Name" --output text | tr '\t' '\n' | sed 's/^/  /'
```

Then run the Databricks-side check in [section 5](#5-databricks-service-principal-checks).

---

## 1. AWS console: which account am I in?

**Symptoms**
- The account menu shows **Projects / Switch project / Monthly spend limit $X / $Y** instead of the normal
  AWS account menu. That's a team or sandbox portal in front of AWS.
- Root sign-in fails with *"Your root user credentials are not valid or sign-in as root is currently disabled
  for this account"*.

**Diagnosis**
- In the AWS console account menu (top right), check **Account ID**, **Account name** and **Federated user**.
  `AccountFullAccessRole/...` means you came in through the portal's federation, not as root.
- With **multi-session** turned on, the left panel lists your *other active sessions*. Here that included
  `architect-dbx-Team Management Account (<management-account-id>)`, the organization's management account.
- From the CLI:

  ```bash
  aws sts get-caller-identity                     # account + role you're using
  aws organizations describe-organization \
    --query 'Organization.{Id:Id,Management:MasterAccountId}'   # works from member accounts too
  ```

**Root cause.** The workload account is a **member** of an AWS Organization. The organization removed the member
account's root credentials (centralized root access), so "Forgot password" can't restore root.

**Fix.** You don't need root. Use the federated admin role in the member account for deployment, and the
management-account session for org guardrails ([section 7](#7-failed-credential-validation-checks-org-guardrails)).
Guardrails apply to member-account root users too, so root wouldn't help with them anyway.

---

## 2. AWS bootstrap: state bucket, OIDC provider, GitHub role

🟦 **Member CloudShell.** Idempotent: it creates whatever is missing and refreshes the trust policy. Safe to
re-run before a demo.

```bash
REGION="us-east-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="dbx-architect-lab-tfstate-$ACCOUNT_ID"
ROLE=gh-dbx-platform-infra-aws
# Must match the token's `sub` claim exactly (see section 4). This org uses the ID-based format.
SUB_PREFIX="repo:DBxArchitectLab@336295900/dbx-platform-infra-aws@1404588117"

echo "== State bucket"
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  echo "OK: $STATE_BUCKET ($(aws s3api get-bucket-location --bucket "$STATE_BUCKET" --query LocationConstraint --output text))"
else
  aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "CREATED: $STATE_BUCKET"
fi

echo "== GitHub OIDC provider"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1 \
  && echo "OK: exists" \
  || { aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
         --client-id-list sts.amazonaws.com >/dev/null && echo "CREATED"; }

echo "== GitHub role"
cat > gh-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": [
          "${SUB_PREFIX}:environment:dev",
          "${SUB_PREFIX}:environment:uat",
          "${SUB_PREFIX}:environment:prod"
        ]
      }
    }
  }]
}
EOF
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document file://gh-trust.json
  echo "OK: role exists (trust policy refreshed)"
else
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document file://gh-trust.json \
    --max-session-duration 7200 >/dev/null && echo "CREATED: role"
fi
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

echo "== Summary"
echo "AWS_ROLE_ARN = $(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
aws iam get-role --role-name "$ROLE" --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
```

**Check:** the printed `AWS_ROLE_ARN` must equal the `AWS_ROLE_ARN` secret in the GitHub `dev`, `uat` and `prod`
environments. The only AWS secret GitHub needs is the role ARN: no access keys and no account ID.

`EntityAlreadyExists` on `create-open-id-connect-provider` is harmless; the provider is created once per account.

---

## 3. Region mismatch: state bucket in Ohio, repo in N. Virginia

**Symptom.** The state bucket and CloudShell are in **US East (Ohio)**, but the repo was written for `us-east-1`.
The first `terragrunt init` would fail with `NoSuchBucket` or a redirect/region error.

**Root cause.** The console's region selector defaulted to Ohio. AWS has no "Central US" region; Ohio
(`us-east-2`) is the closest match to Azure Central US.

**Fix.** Switch the repo to `us-east-2` everywhere:

| What | File |
| --- | --- |
| State bucket region | `live/root.hcl` (`state_region`) |
| Workspace region, AZs (`us-east-2a`, `us-east-2b`) | `live/{dev,uat,prod}/config.yaml` |
| PrivateLink endpoint services (per region) | `live/{dev,uat,prod}/config.yaml` (`private_link.*_vpce_service`) |
| Metastore region | `live/metastore/config.yaml` |
| OIDC session region | workflow `AWS_REGION` |

**Check** that nothing still points at the old region:

```bash
grep -rn "us-east-1" --include=*.hcl --include=*.yaml --include=*.yml --include=*.tf .
```

- PrivateLink endpoint service names are **different in every region**, not just renamed. Check them against
  <https://docs.databricks.com/aws/en/resources/ip-domain-region>.
- `aws s3api create-bucket` needs `--create-bucket-configuration LocationConstraint=<region>` everywhere except
  `us-east-1`.

---

## 4. GitHub → AWS: `Not authorized to perform sts:AssumeRoleWithWebIdentity`

**Symptom** (⬛ GitHub Actions, step *Configure AWS credentials*):

```
Assuming role with OIDC   (repeated ~12 times)
Error: Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**What this means.** GitHub reached AWS, but the role's trust policy didn't match the token. The usual causes are:
- the `sub` claim doesn't match;
- the OIDC provider is missing, or doesn't have the `sts.amazonaws.com` audience;
- the `AWS_ROLE_ARN` secret is wrong;
- an org guardrail blocks it.

### Step 1: check AWS (🟦 Member CloudShell)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws iam get-role --role-name gh-dbx-platform-infra-aws --query Role.Arn --output text       # = AWS_ROLE_ARN secret?
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com \
  --query '{audiences:ClientIDList,url:Url}'                                                 # audiences has sts.amazonaws.com?
aws iam get-role --role-name gh-dbx-platform-infra-aws --query Role.AssumeRolePolicyDocument # sub values?
```

### Step 2: print the token's actual claims (⬛ GitHub Actions)

Add this step temporarily to the workflow, right before *Configure AWS credentials*. It prints the token's
claims, not the token:

```yaml
      - name: Debug OIDC claims (temporary)
        shell: bash
        run: |
          TOKEN=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
          PAYLOAD=$(echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+')
          while [ $(( ${#PAYLOAD} % 4 )) -ne 0 ]; do PAYLOAD="$PAYLOAD="; done
          echo "$PAYLOAD" | base64 -d | jq '{sub, aud, repository, environment}'
```

**What it showed:**

```json
{
  "sub": "repo:DBxArchitectLab@336295900/dbx-platform-infra-aws@1404588117:environment:dev",
  "aud": "sts.amazonaws.com",
  "repository": "DBxArchitectLab/dbx-platform-infra-aws",
  "environment": "dev"
}
```

**Root cause.** The org uses GitHub's **ID-based subject format**, so the claim includes `@<org-id>` and `@<repo-id>`.
The trust policy expected the classic `repo:DBxArchitectLab/dbx-platform-infra-aws:environment:dev`. Casing
wasn't the issue: the merge commit text, *"Merge pull request #1 from DBxArchitectLab/…"*, shows the org's real
spelling.

**Fix.** Set `SUB_PREFIX` to the printed value (minus `:environment:dev`) and re-run the bootstrap script in
[section 2](#2-aws-bootstrap-state-bucket-oidc-provider-github-role). Then click **Re-run jobs**; the trust
policy change takes effect immediately, so there's nothing to push. Remove the debug step afterwards.

The numeric IDs don't change if the org or repo is renamed, so this format is safer: a recreated repo with the
same name can't take over the role.

---

## 5. Databricks service principal checks

The service principal is a **Databricks** identity (account console → **User management → Service
principals**), not an AWS IAM one. `DATABRICKS_CLIENT_ID` is its Application ID, and `DATABRICKS_CLIENT_SECRET`
is an OAuth secret from its **Secrets** tab, which is shown only once.

🟦 **Any CloudShell.** Prompts for the values, so nothing lands in shell history:

```bash
read -p  "Databricks account ID: " DBX_ACCOUNT_ID
read -p  "SP client ID: "          DBX_CLIENT_ID
read -sp "SP client secret: "      DBX_CLIENT_SECRET; echo
ACC="https://accounts.cloud.databricks.com"

echo "== 1. OAuth token"
RESP=$(curl -s -u "$DBX_CLIENT_ID:$DBX_CLIENT_SECRET" -d "grant_type=client_credentials&scope=all-apis" \
  "$ACC/oidc/accounts/$DBX_ACCOUNT_ID/v1/token")
unset DBX_CLIENT_SECRET
TOKEN=$(echo "$RESP" | jq -r '.access_token // empty')
[ -n "$TOKEN" ] && echo "OK: token issued" || echo "FAIL: $RESP"

echo "== 2. Metastores (needs account admin)"
curl -s -H "Authorization: Bearer $TOKEN" "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/metastores" \
  | jq -r 'if (.metastores | length) > 0 then (.metastores[] | "\(.region)  \(.name)  \(.metastore_id)")
           elif .error_code then "FAIL: \(.error_code) \(.message)" else "none" end'

echo "== 3. Workspaces"
curl -s -H "Authorization: Bearer $TOKEN" "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/workspaces" \
  | jq -r 'if type == "array" then (if length > 0 then (.[] | "\(.aws_region)  \(.workspace_name)  \(.workspace_status)  https://\(.deployment_name).cloud.databricks.com") else "none" end)
           elif .error_code then "FAIL: \(.error_code) \(.message)" else . end'

echo "== 4. Group DBX_Architect_Lab_Admin"
GROUP=$(curl -s -G -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'filter=displayName eq "DBX_Architect_Lab_Admin"' \
  "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/scim/v2/Groups")
if [ "$(echo "$GROUP" | jq -r '.totalResults // 0')" -gt 0 ]; then
  echo "OK: group found"; echo "$GROUP" | jq -r '.Resources[0].members // [] | .[] | "  member: \(.display)"'
else
  echo "FAIL: group not found"
fi

echo "== 5. SP is in the group?"
SP_ID=$(curl -s -G -H "Authorization: Bearer $TOKEN" --data-urlencode "filter=applicationId eq \"$DBX_CLIENT_ID\"" \
  "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/scim/v2/ServicePrincipals" | jq -r '.Resources[0].id // empty')
echo "$GROUP" | jq -e --arg id "$SP_ID" '.Resources[0].members // [] | map(.value) | index($id)' >/dev/null \
  && echo "OK: SP is a member" || echo "FAIL: SP is NOT a member"
```

| Output | Fix |
| --- | --- |
| Step 1 `invalid_client` | Wrong client ID or secret, or the secret was revoked or expired. Generate a new secret and update the GitHub secret in all three environments. |
| Step 2/3 `PERMISSION_DENIED` | SP → **Roles** → turn on **Account admin** |
| Step 2 already lists a metastore in `us-east-2` | Don't run the `metastore` stack. Put that ID in `DATABRICKS_METASTORE_ID`. |
| Step 4/5 `FAIL` | Create `DBX_Architect_Lab_Admin` and add the SP and your user |

If a secret is ever pasted into chat, a ticket or a terminal, rotate it afterwards: generate a new one and
delete the old one in the SP's **Secrets** tab, then update the GitHub secrets. Clear CloudShell history with
`history -c && rm -f ~/.bash_history`.

---

## 6. `ENTERPRISE` pricing tier required (PrivateLink)

**Symptom** (⬛ `dev-dbxarchitectlab-workspace` apply):

```
Error: cannot create mws vpc endpoint: Feature cannot be accessed. Account *** does not have one of required pricing tier(s) ENTERPRISE.
  with module.network.databricks_mws_vpc_endpoint.workspace[0]
Error: cannot create mws private access settings: Feature cannot be accessed. ... ENTERPRISE.
```

**Root cause.** Back-end PrivateLink (VPC endpoint registrations and private access settings) is an
**Enterprise-tier** feature. The Databricks account is **Premium**.

**Fix.** In each `live/<env>/config.yaml`:

```yaml
private_link:
  enabled: false
```

Clusters reach the control plane through the NAT gateway instead. On the next apply, Terraform **deletes** the
PrivateLink resources it had already created in AWS: two endpoint subnets, the endpoint security group, and four
interface endpoints (STS, Kinesis, workspace, relay). That also stops their hourly cost. Destroying the interface
endpoints takes about 3 minutes each.

---

## 7. `Failed credential validation checks` (org guardrails)

**Symptom** (⬛ workspace apply). The same error after a re-run, so it isn't IAM propagation:

```
Error: cannot create mws credentials: Failed credential validation checks: please use a valid cross account IAM role with permissions setup correctly.
  with module.cross_account_role.databricks_mws_credentials.this
```

When the cross-account role is registered, Databricks' control plane (AWS account **`414351767826`**) assumes the
role and dry-runs EC2 calls with it. Something on the AWS side blocked that. The diagnosis below narrows down
what, step by step.

### 7.1 Check the role itself (🟦 Member CloudShell)

```bash
ROLE=dbx-architect-lab-dev-crossaccount
ARN=$(aws iam get-role --role-name $ROLE --query Role.Arn --output text); echo "Role: $ARN"

echo "== Trust policy (expect Principal arn:aws:iam::414351767826:root + sts:ExternalId = Databricks account ID)"
aws iam get-role --role-name $ROLE --query Role.AssumeRolePolicyDocument --output json
echo "== Permissions boundary (expect null)"
aws iam get-role --role-name $ROLE --query Role.PermissionsBoundary --output json
echo "== Inline policies (expect <role>-policy)"
aws iam list-role-policies --role-name $ROLE --output text

echo "== Policy simulation (no request context)"
aws iam simulate-principal-policy --policy-source-arn "$ARN" \
  --action-names ec2:RunInstances ec2:RequestSpotInstances ec2:CreateTags ec2:DescribeInstances \
                 ec2:CreateVolume ec2:AttachVolume ec2:DescribeVpcs ec2:DescribeSubnets \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
```

**What we saw:** the trust policy, boundary (`null`) and inline policy were all correct, but the simulation showed
`explicitDeny` for **every** EC2 action, including `DescribeVpcs`.

### 7.2 Rule out the role's own policy

The generated `databricks_aws_crossaccount_policy` (`policy_type = "customer"`) contains only `Allow` statements:
EC2 actions plus `iam:CreateServiceLinkedRole` for spot. An explicit deny therefore has to come from an
**organization guardrail**; the policy simulator includes SCPs.

To render the policy yourself (local Terraform, no credentials needed):

```hcl
terraform {
  required_providers {
    databricks = { source = "databricks/databricks" }
  }
}
provider "databricks" {
  host  = "https://accounts.cloud.databricks.com"
  token = "dummy"
}
data "databricks_aws_crossaccount_policy" "this" {
  policy_type = "customer"
}
output "policy" {
  value = data.databricks_aws_crossaccount_policy.this.json
}
```

Then run `terraform init && terraform plan`.

### 7.3 Dry-run EC2 as yourself (🟦 Member CloudShell)

```bash
SUBNET=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=vpc-dbx-architect-lab-dev-private-us-east-2a" \
  --query 'Subnets[0].SubnetId' --output text)
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
echo "-- on-demand:"; aws ec2 run-instances --dry-run --image-id $AMI --instance-type m5d.xlarge --subnet-id $SUBNET 2>&1 | tail -1
echo "-- spot:";      aws ec2 run-instances --dry-run --image-id $AMI --instance-type m5d.xlarge --subnet-id $SUBNET \
                        --instance-market-options MarketType=spot 2>&1 | tail -1
```

`DryRunOperation` means *"would have succeeded"*. Both succeeded, so EC2 isn't blocked outright.

### 7.4 Simulate with region context (🟦 Member CloudShell)

```bash
for REG in us-east-2 us-east-1 us-west-2 us-west-1; do
  echo "== $REG"
  aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/dbx-architect-lab-dev-crossaccount \
    --action-names ec2:DescribeVpcs ec2:RunInstances \
    --context-entries "ContextKeyName=aws:RequestedRegion,ContextKeyValues=$REG,ContextKeyType=string" \
    --query 'EvaluationResults[].{action:EvalActionName,decision:EvalDecision,allowedByOrg:OrganizationsDecisionDetail.AllowedByOrganizations}' \
    --output table
done
```

**What we saw:** with `us-east-2` everything was `allowed` / `allowedByOrg = True`. The earlier `explicitDeny` was
an SCP with an `aws:RequestedRegion` condition, which evaluates as a deny when the simulator has no region. So
SCPs didn't block EC2 in Ohio, and the remaining suspect was something stopping **an outside account
(Databricks) from assuming the role**. The simulator can't show that, because it's a resource control policy (RCP).

### 7.5 List the org guardrails (🟥 Management CloudShell)

Confirm access first: **AWS Organizations → Policies** should load and show *Service control policies* and
*Resource control policies* as **Enabled**.

```bash
ACCT=<member-account-id>        # the workload account, e.g. the one hosting the workspaces
OUT=~/org-policies; mkdir -p "$OUT"

aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table   # must be the management account

# account -> OU(s) -> root
CHAIN=("$ACCT"); CUR=$ACCT
while :; do
  PARENT=$(aws organizations list-parents --child-id "$CUR" --query 'Parents[0].Id' --output text)
  [ -z "$PARENT" ] || [ "$PARENT" = "None" ] && break
  CHAIN+=("$PARENT"); [[ $PARENT == r-* ]] && break; CUR=$PARENT
done
echo "Hierarchy: ${CHAIN[*]}"

for T in "${CHAIN[@]}"; do
  for F in SERVICE_CONTROL_POLICY RESOURCE_CONTROL_POLICY; do
    for P in $(aws organizations list-policies-for-target --target-id "$T" --filter "$F" --query 'Policies[].Id' --output text); do
      NAME=$(aws organizations describe-policy --policy-id "$P" --query 'Policy.PolicySummary.Name' --output text)
      echo; echo "######## $F on $T: $P ($NAME)"
      aws organizations describe-policy --policy-id "$P" --query 'Policy.Content' --output text \
        | jq . | tee "$OUT/${P}_${NAME// /_}.json"
    done
  done
done

echo; echo "== Relevant Deny statements"
for f in "$OUT"/*.json; do
  jq -r --arg f "$(basename "$f")" '[.Statement] | flatten | .[] | select(.Effect=="Deny")
    | select(tostring | test("RequestedRegion|AssumeRole|sts:|PrincipalOrgID|PrincipalAccount|PrincipalArn"))
    | "\($f): Sid=\(.Sid // "-")"' "$f"
done
```

**What we found** (attached at the org root):

| Policy | Type | Statement | Effect on Databricks |
| --- | --- | --- | --- |
| `ManagedAccountResourceControlPolicy` (`p-024h10t2bn`) | RCP | `DenyAnyoneOutsideMyOrgAndAWS`: deny `sts:*`, `s3:*` and more when `aws:PrincipalOrgID ≠ ${aws:ResourceOrgID}` | **Root cause.** Databricks `414351767826` is outside the org, so it can't assume the role or use the root bucket |
| `AdvancedModeRegionRestrictionSecurityControlPolicy` (`p-439128bc`) | SCP | `UsEast1Partitional` / `UsWest2Partitional`: only global services in us-east-1 / us-west-2; `RegionFloor`: only us-east-1/2, us-west-2 | Possible blocker if Databricks validates from another region; turned out not to be needed |
| `ManagedAccountSecurityControlPolicy` | SCP | Protects `role/managed/*`, blocks leaving the org | Not relevant |

### 7.6 Fix: exempt Databricks in the RCP (🟥 Management CloudShell)

```bash
cd ~/org-policies
RCP_ID=p-024h10t2bn
cp -n ${RCP_ID}_*.json rcp.backup.json     # untouched copy for rollback

jq '(.Statement[] | select(.Sid=="DenyAnyoneOutsideMyOrgAndAWS")
       .Condition.StringNotEqualsIfExists["aws:PrincipalAccount"]) = ["414351767826"]' \
   rcp.backup.json > rcp.new.json

diff <(jq . rcp.backup.json) <(jq . rcp.new.json)          # only the PrincipalAccount line should be added
echo "size: $(jq -c . rcp.new.json | wc -c) (limit 5120)"

aws organizations update-policy --policy-id $RCP_ID --content "$(jq -c . rcp.new.json)" \
  --query 'Policy.PolicySummary.Name' --output text && echo "RCP updated"

aws organizations describe-policy --policy-id $RCP_ID --query Policy.Content --output text \
  | jq '.Statement[] | select(.Sid=="DenyAnyoneOutsideMyOrgAndAWS") | .Condition'
```

**Why this is safe.** Keys inside one condition operator are ANDed, so the statement now denies only when the
caller is outside the org **and** isn't Databricks. Databricks still only gets what each role's trust policy and
each bucket policy allow; the RCP was just the org-wide ceiling.

**Rollback:**

```bash
aws organizations update-policy --policy-id p-024h10t2bn --content "$(jq -c . ~/org-policies/rcp.backup.json)"
```

After about a minute, re-run the workspace `apply`. `databricks_mws_credentials` succeeds, followed by the storage
configuration, workspace and assignments. The Unity Catalog role in `workspace-bootstrap` is also assumed from
`414351767826`, so the same exception covers it.

### 7.7 (Only if still failing) SCP region exception, and the 5,120-character limit

Exempting the Databricks roles from the us-east-1 / us-west-2 denies pushed the region SCP to **5,266
characters**, over AWS's **5,120** limit, so `update-policy` rejects it. It turned out not to be needed. If it
ever is, split the policy (the root allows up to 5 SCPs):

```bash
cd ~/org-policies
SCP_ID=p-439128bc; ROOT=r-mxob; ACCT=<member-account-id>
cp -n ${SCP_ID}_*.json scp.backup.json

jq --arg arn "arn:aws:iam::$ACCT:role/dbx-architect-lab-*" \
  '(.Statement[] | select(.Sid=="UsEast1Partitional" or .Sid=="UsWest2Partitional")
     .Condition.ArnNotLike) = {"aws:PrincipalArn": [$arn]}' scp.backup.json > scp.new.json
jq '.Statement |= map(select(.Sid=="UsEast1Partitional"))' scp.new.json > scp.partA.json
jq '.Statement |= map(select(.Sid=="UsWest2Partitional" or .Sid=="RegionFloor"))' scp.new.json > scp.partB.json
echo "A: $(jq -c . scp.partA.json | wc -c)  B: $(jq -c . scp.partB.json | wc -c)  (each < 5120)"

# Attach part B first so the rules never lapse, then shrink the original to part A
B_ID=$(aws organizations create-policy --type SERVICE_CONTROL_POLICY \
  --name AdvancedModeRegionRestrictionSecurityControlPolicy-Part2 \
  --description "Split from $SCP_ID (size limit)" \
  --content "$(jq -c . scp.partB.json)" --query Policy.PolicySummary.Id --output text)
aws organizations attach-policy --policy-id "$B_ID" --target-id $ROOT && echo "$B_ID" > scp.partB.id
aws organizations update-policy --policy-id $SCP_ID --content "$(jq -c . scp.partA.json)"
```

**Rollback:**

```bash
cd ~/org-policies
aws organizations update-policy --policy-id p-439128bc --content "$(jq -c . scp.backup.json)"
B_ID=$(cat scp.partB.id)
aws organizations detach-policy --policy-id "$B_ID" --target-id r-mxob
aws organizations delete-policy --policy-id "$B_ID"
```

The policy names (`ManagedAccount…`, `AdvancedMode…`) suggest the portal manages them and may overwrite edits.
If access errors come back later, re-run 7.5 and check that the exception is still there.

---

## 8. Can't open the workspace: admin group membership

**Symptom.** The workspace apply succeeded, but signing in to the workspace URL fails (not a member / no access).

**Root cause.** The workspace stack grants **ADMIN** to the account group `DBX_Architect_Lab_Admin`
(`databricks_mws_permission_assignment`). The user signing in wasn't a member of that group.

🟦 **Any CloudShell.** Ensures the user exists and is in the group, then shows the workspace's permission
assignments:

```bash
read -p  "Databricks account ID: " DBX_ACCOUNT_ID
read -p  "SP client ID: "          DBX_CLIENT_ID
read -sp "SP client secret: "      DBX_CLIENT_SECRET; echo
USER_EMAIL="dbxarchitectlab@gmail.com"
GROUP_NAME="DBX_Architect_Lab_Admin"
WS_NAME="dbw-dbx-architect-lab-dev"            # or -uat / -prod
ACC="https://accounts.cloud.databricks.com/api/2.0/accounts/$DBX_ACCOUNT_ID"

TOKEN=$(curl -s -u "$DBX_CLIENT_ID:$DBX_CLIENT_SECRET" -d "grant_type=client_credentials&scope=all-apis" \
  "https://accounts.cloud.databricks.com/oidc/accounts/$DBX_ACCOUNT_ID/v1/token" | jq -r '.access_token // empty')
unset DBX_CLIENT_SECRET
H=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

echo "== User"
USER_ID=$(curl -s -G "${H[@]}" --data-urlencode "filter=userName eq \"$USER_EMAIL\"" "$ACC/scim/v2/Users" \
  | jq -r '.Resources[0].id // empty')
if [ -z "$USER_ID" ]; then
  USER_ID=$(curl -s "${H[@]}" -X POST "$ACC/scim/v2/Users" \
    -d "{\"schemas\":[\"urn:ietf:params:scim:schemas:core:2.0:User\"],\"userName\":\"$USER_EMAIL\"}" | jq -r '.id')
  echo "CREATED $USER_EMAIL ($USER_ID)"
else
  echo "OK: $USER_EMAIL ($USER_ID)"
fi

echo "== Group membership"
GROUP=$(curl -s -G "${H[@]}" --data-urlencode "filter=displayName eq \"$GROUP_NAME\"" "$ACC/scim/v2/Groups")
GROUP_ID=$(echo "$GROUP" | jq -r '.Resources[0].id')
if echo "$GROUP" | jq -e --arg u "$USER_ID" '.Resources[0].members // [] | map(.value) | index($u)' >/dev/null; then
  echo "OK: already a member"
else
  curl -s "${H[@]}" -X PATCH "$ACC/scim/v2/Groups/$GROUP_ID" -d "{
    \"schemas\": [\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"],
    \"Operations\": [{\"op\": \"add\", \"value\": {\"members\": [{\"value\": \"$USER_ID\"}]}}]}" >/dev/null
  echo "ADDED to $GROUP_NAME"
fi
curl -s "${H[@]}" "$ACC/scim/v2/Groups/$GROUP_ID" | jq -r '.members[]? | "  - \(.display)"'

echo "== Workspace"
WS=$(curl -s "${H[@]}" "$ACC/workspaces" | jq -c --arg n "$WS_NAME" '.[] | select(.workspace_name==$n)')
WS_ID=$(echo "$WS" | jq -r .workspace_id)
echo "Status: $(echo "$WS" | jq -r .workspace_status)  URL: https://$(echo "$WS" | jq -r .deployment_name).cloud.databricks.com"
curl -s "${H[@]}" "$ACC/workspaces/$WS_ID/permissionassignments" \
  | jq -r '.permission_assignments[]? | "  - \(.principal.display_name // .principal.user_name // .principal.group_name): \(.permissions | join(","))"'
```

**Expected:** the user is listed as a member, the status is `RUNNING`, and the assignments include
`DBX_Architect_Lab_Admin: ADMIN`. Sign in at the printed URL in a **private window**. Group membership can take a
minute or two to take effect.

---

## 9. Dev catalog visible in the uat workspace

**Symptom.** After the uat stacks ran, the uat workspace listed `dbxarchitectlab_dev`.

**Root cause.** The uat run didn't create it; the workspace stack has no catalog code. All three workspaces share
**one Unity Catalog metastore**, and catalogs, external locations and storage credentials are visible in every
attached workspace unless they're bound to specific ones.

**Fix (in code).** `workspace-bootstrap` now isolates each environment's objects and binds them to its own
workspace (`workspace_id` comes from the workspace stack's output):

| Resource | Setting |
| --- | --- |
| `databricks_catalog` | `isolation_mode = "ISOLATED"` + `databricks_workspace_binding` (`catalog`) |
| `databricks_storage_credential` | `isolation_mode = "ISOLATION_MODE_ISOLATED"` + binding (`storage_credential`) |
| `databricks_external_location` | `isolation_mode = "ISOLATION_MODE_ISOLATED"` + binding (`external_location`) |

Catalogs use `ISOLATED`/`OPEN`; credentials and locations use `ISOLATION_MODE_ISOLATED`/`ISOLATION_MODE_OPEN`.

**Rollout:** re-apply dev bootstrap first, so the dev catalog disappears from uat, then uat, then prod. The plan
should show **in-place updates plus 3 new bindings, and no replacements**. Stop if a catalog shows as
destroy/create.

**Check** in each workspace (**Catalog** explorer or a SQL editor):

```sql
SHOW CATALOGS;   -- dev shows only dbxarchitectlab_dev, uat only dbxarchitectlab_uat, prod only dbxarchitectlab_prod
```

(Built-in catalogs such as `system`, `samples` and the workspace's own default catalog can also appear.)

---

## 10. Cost hygiene while troubleshooting

A failed workspace apply leaves already-created AWS resources running. The **NAT gateway** (and interface
endpoints, if PrivateLink is on) bill by the hour. If a fix will take more than a day or two:

- Run the workflow for that stack with action **`destroy`**, then **`apply`** again once it's fixed.
- When **switching AWS accounts**, run `destroy` **before** changing `AWS_ROLE_ARN`. State lives in a per-account
  bucket (`dbx-architect-lab-tfstate-<account-id>`), so Terraform loses track of the old resources after the switch.

Check what's still running (🟦 Member CloudShell):

```bash
aws ec2 describe-nat-gateways --region us-east-2 --filter "Name=state,Values=available" \
  --query 'NatGateways[].[NatGatewayId,VpcId,CreateTime]' --output table
aws ec2 describe-vpc-endpoints --region us-east-2 \
  --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,VpcEndpointType,State]' --output table
aws ec2 describe-instances --region us-east-2 --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Vendor`]|[0].Value]' --output table
```

---

## Lessons learned

1. **Read the error's source before changing code.** `AssumeRoleWithWebIdentity` is a trust-policy problem,
   `ENTERPRISE` is a Databricks tier problem, and `Failed credential validation checks` turned out to be an
   AWS Organizations problem. None of them were Terraform bugs.
2. **Print what the other side sends.** The OIDC `sub` claim was not the documented default; printing it
   solved the problem in one step.
3. **The IAM policy simulator includes SCPs but not RCPs**, and evaluates missing context keys (like
   `aws:RequestedRegion`) in ways that can look like a deny. Use `--context-entries`, and compare against a role
   you know works.
4. **Databricks is an outside AWS account (`414351767826`).** Any "deny outside my org" data-perimeter control
   needs an exception for it, covering both role assumption (`sts`) and bucket access (`s3`).
5. **A shared metastore means shared visibility.** Isolate and bind catalogs, external locations and credentials
   per environment.
6. **SCPs are limited to 5,120 characters.** Check the size with `jq -c . | wc -c` before `update-policy`, and
   always keep a backup copy for rollback.
7. **Destroy before you walk away** when a deployment is half-applied; NAT gateways bill by the hour.
