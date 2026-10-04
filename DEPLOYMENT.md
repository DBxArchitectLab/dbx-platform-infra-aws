# Deployment guide

How to deploy this repository into an AWS account and a Databricks account (on AWS) using the GitHub
Actions workflow (`.github/workflows/terragrunt-deploy.yml`), or locally.

Deployment order:

```
0. Tools  →  1. Repo config  →  2. AWS prerequisites  →  3. Databricks account  →  4. GitHub setup
                                                                                        │
   5. Deploy:  metastore  →  dev-workspace  →  dev-workspace-bootstrap  →  (uat, prod)
```

Values used throughout this guide (change them if yours differ):

| Name | Value | Defined in |
| --- | --- | --- |
| AWS region | `us-east-1` | `live/*/config.yaml`, `live/metastore/config.yaml`, `live/root.hcl` (state), workflow `AWS_REGION` |
| Terraform state bucket | `dbx-architect-lab-tfstate-<aws-account-id>` | `live/root.hcl` |
| Workspace root buckets | `dbx-architect-lab-<env>-root-<aws-account-id>` | `live/<env>/config.yaml` (`root_bucket.name_prefix`) |
| Unity Catalog buckets | `dbx-architect-lab-<env>-uc-<aws-account-id>` | `live/<env>/workspace-bootstrap/s3-storage-config.yaml` |
| Admin group | `DBX_Architect_Lab_Admin` | `live/<env>/config.yaml`, `live/metastore/config.yaml` |
| GitHub repo | `DBxArchitectLab/dbx-platform-infra-aws` | GitHub OIDC trust policy (step 2.2) |

---

## 0. Tools (for local runs and the one-time setup)

| Tool | Version | Notes |
| --- | --- | --- |
| AWS CLI | v2 | For steps 2.x. `aws configure sso` or `aws configure` |
| Terraform | ≥ 1.10 (CI uses 1.14.6) | 1.10+ is required for S3 native state locking (`use_lockfile`) |
| Terragrunt | recent (CI uses 0.99.4) | Older releases (e.g. 0.63) don't support `use_lockfile` in `remote_state`; upgrade to match CI |
| Databricks CLI | optional | Only for local runs as your own user (`databricks auth login`) |

## 1. Finish the repo configuration

Edit and commit these before the first run.

- [ ] **Region.** Everything defaults to `us-east-1`. To change it, update `region` in every
      `live/<env>/config.yaml`, `metastore.region` in `live/metastore/config.yaml`, `availability_zones`, and
      the PrivateLink service names (below). The metastore and all workspaces must be in the same region.
- [ ] **PrivateLink (`private_link.enabled` in `live/<env>/config.yaml`).** On by default.
      **Back-end PrivateLink requires the Databricks Enterprise tier.**
      On a Premium account, set `enabled: false`; clusters then reach the control plane through the NAT gateway.
- [ ] **PrivateLink endpoint service names.** `workspace_vpce_service` and `relay_vpce_service` are
      region-specific. Check the values against the Databricks table
      ("PrivateLink VPC endpoint services") at
      <https://docs.databricks.com/aws/en/resources/ip-domain-region>.
- [ ] **Availability zones.** At least two. With PrivateLink, pick AZs where the Databricks endpoint services
      are offered. If endpoint creation fails with "service not available in AZ", choose other AZs.
- [ ] **CIDRs.** dev, uat and prod use `10.0.0.0/22`, `10.1.0.0/22` and `10.2.0.0/22`. Change them if they
      overlap with networks you plan to peer with.
- [ ] **Grant principals.** `grant_principals` in `catalog-config.yaml` and `external-location-config.yaml`
      (e.g. `dbxarchitectlab@gmail.com`) must be users or groups that exist in the Databricks account.
- [ ] **Metastore owner.** `metastore.owner` in `live/metastore/config.yaml` must exist in the account.
      Recommended: the group `DBX_Architect_Lab_Admin` (step 3).

## 2. AWS prerequisites

Run these as an AWS user/role with administrator access in the target account.

```bash
export AWS_REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "$ACCOUNT_ID"
```

### 2.1 Terraform state bucket

`live/root.hcl` expects `dbx-architect-lab-tfstate-<account-id>` in `us-east-1`. State locking uses an S3 lock
file, so no DynamoDB table is needed.

```bash
STATE_BUCKET="dbx-architect-lab-tfstate-$ACCOUNT_ID"

aws s3api create-bucket --bucket "$STATE_BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

(New S3 buckets are encrypted with SSE-S3 by default. For a region other than `us-east-1`, add
`--create-bucket-configuration LocationConstraint=<region>`.)

### 2.2 IAM role for GitHub Actions (OIDC, no long-lived keys)

Create the GitHub OIDC identity provider (once per AWS account; skip if it already exists):

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

Create the role. The trust policy only allows workflow runs in the `dev`, `uat` and `prod` GitHub environments
of this repo:

```bash
cat > gh-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": [
          "repo:DBxArchitectLab/dbx-platform-infra-aws:environment:dev",
          "repo:DBxArchitectLab/dbx-platform-infra-aws:environment:uat",
          "repo:DBxArchitectLab/dbx-platform-infra-aws:environment:prod"
        ]
      }
    }
  }]
}
EOF

aws iam create-role --role-name gh-dbx-platform-infra-aws \
  --assume-role-policy-document file://gh-trust.json \
  --max-session-duration 7200

aws iam attach-role-policy --role-name gh-dbx-platform-infra-aws \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

aws iam get-role --role-name gh-dbx-platform-infra-aws --query Role.Arn --output text
# → save this as the AWS_ROLE_ARN GitHub secret
```

`AdministratorAccess` keeps a lab simple. The stacks create VPCs, subnets, NAT/internet gateways, EIPs,
security groups, VPC endpoints, S3 buckets and IAM roles/policies. For production, replace it with a policy
scoped to those services (EC2/VPC, S3, IAM role management) plus read/write on the state bucket.

### 2.3 Service quotas

Each environment uses one VPC, one Elastic IP and one NAT gateway. The defaults (5 VPCs and 5 EIPs per region)
cover dev/uat/prod, unless other workloads already use them.

## 3. Databricks account

1. **Account and ID.** Sign in to the account console at <https://accounts.cloud.databricks.com> and copy the
   account ID from the user menu (top right). If you don't have a Databricks-on-AWS account yet, create one
   via AWS Marketplace or databricks.com. Check the plan: **Enterprise** is needed for PrivateLink (step 1).
2. **Create a service principal for Terraform.** **User management → Service principals → Add service
   principal**, e.g. `sp-dbx-platform-infra-aws`. Open it, then:
   - **Roles** tab → turn on **Account admin**.
   - **Secrets** tab → **Generate secret**. Copy the **client ID** and **secret** now; the secret is only
     shown once. These become `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`.
3. **Create the group `DBX_Architect_Lab_Admin`** (**User management → Groups**) and add the service
   principal and your user to it. The workspace stack makes this group a workspace admin, which is also how the
   service principal gets access to each workspace for the `workspace-bootstrap` stack.
4. **Add the users** named in the `grant_principals` lists (**User management → Users**), if they don't
   exist yet.
5. **Check for an existing metastore.** Go to **Catalog** in the account console. An account can have only one
   metastore per region, so if one already exists in `us-east-1` the `metastore` stack will fail. Either:
   - **Use it:** skip the `metastore` stack, copy that metastore's ID for step 4, and make
     `DBX_Architect_Lab_Admin` its admin; or
   - **Replace it:** delete it (only if nothing uses it), then deploy the `metastore` stack.

The service principal creates the storage credential, external location and catalog in
`workspace-bootstrap`, so it must be a metastore admin. Setting `metastore.owner` to
`DBX_Architect_Lab_Admin`, with the service principal in that group, covers this.

## 4. GitHub setup

1. **Merge to `main`.** A workflow that you start manually only appears in the **Actions** tab once it
   exists on the default branch.
2. **Create environments** under **Settings → Environments**: `dev`, `uat`, `prod`. The names must match
   the OIDC trust policy (step 2.2). Consider adding required reviewers on `prod`.
3. **Add these secrets to each environment:**

   | Secret | Value |
   | --- | --- |
   | `AWS_ROLE_ARN` | ARN of `gh-dbx-platform-infra-aws` (step 2.2) |
   | `DATABRICKS_ACCOUNT_ID` | account ID (step 3.1) |
   | `DATABRICKS_CLIENT_ID` | service principal client ID (step 3.2) |
   | `DATABRICKS_CLIENT_SECRET` | service principal OAuth secret (step 3.2) |
   | `DATABRICKS_METASTORE_ID` | metastore ID (set after step 5.1 or 3.5; any placeholder until then) |

   The `metastore` stack runs in the `dev` environment. `DEPLOY_SP_APPLICATION_ID` is derived from
   `DATABRICKS_CLIENT_ID` in the workflow, so it doesn't need its own secret.

## 5. Deploy

Go to **Actions → Terragrunt Deploy Stacks → Run workflow**, choose a **stack** and an **action**. For
each stack, run `plan` first, review the log, then run `apply`.

### 5.1 Metastore (once per region)

| Stack | Action |
| --- | --- |
| `metastore` | `plan`, then `apply` |

Copy the metastore ID from the `metastore_id` output at the end of the apply log (or from the account
console: **Catalog → your metastore**). Set it as `DATABRICKS_METASTORE_ID` in the `dev`, `uat` and `prod`
environments. They share the metastore because they're in the same region.

### 5.2 dev

| Order | Stack | Creates |
| --- | --- | --- |
| 1 | `dev-dbxarchitectlab-workspace` | VPC, subnets, NAT gateway, security groups, S3/STS/Kinesis endpoints, PrivateLink endpoints and their Databricks registrations, cross-account IAM role, root bucket, workspace, metastore assignment, admin group assignment |
| 2 | `dev-dbxarchitectlab-workspace-bootstrap` | Unity Catalog S3 bucket, IAM role, storage credential, external location, catalog, grants, cluster policies, secret scope |

Workspace creation usually takes a few minutes. The `workspace-bootstrap` stack reads the workspace URL from
the `workspace` stack's state, so it must be applied afterwards.

### 5.3 uat and prod

Repeat 5.2 with the `uat-*` stacks, then the `prod-*` stacks.

## 6. Verify

- Account console → **Workspaces**: the workspace is **Running**; open its URL.
- **Catalog:** the catalog from `catalog-config.yaml` is listed and attached to the metastore.
- **Catalog → External data → External locations:** **Test connection** succeeds for the external location.
- **Compute → Policies:** the cluster policies from `cluster-policy-config.yaml` exist.
- **Settings → Identity and access:** `DBX_Architect_Lab_Admin` is a workspace admin.
- Start a small cluster to confirm the network path (NAT and/or PrivateLink) to the control plane works.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC trust `sub` doesn't match `repo:DBxArchitectLab/dbx-platform-infra-aws:environment:<env>`, or the job isn't running in a GitHub environment |
| `terragrunt init` fails: `NoSuchBucket` | State bucket from step 2.1 missing, or created in another account/region |
| `get_env` error for `DATABRICKS_*` | Secret missing in the GitHub environment the stack runs in |
| Databricks `401` / `invalid_client` | Wrong `DATABRICKS_CLIENT_ID`/`SECRET`, or the secret expired (regenerate it in the account console) |
| `databricks_mws_*` permission denied | Service principal isn't an account admin (step 3.2) |
| Workspace creation fails with a PrivateLink / private access settings error | Account isn't on the Enterprise tier; set `private_link.enabled: false` |
| VPC endpoint: "service not available in AZ" / service name not found | Wrong `*_vpce_service` for the region, or AZs not supported by the endpoint service |
| `databricks_mws_credentials` fails validating the role | IAM propagation; re-run `apply` |
| External location validation fails (`AccessDenied` assuming role) | IAM propagation; re-run `apply`. If it persists, compare the role's trust policy with the storage credential's external ID |
| Metastore create fails: region already has a metastore | See step 3.5 |
| `BucketAlreadyExists` | Bucket names are global; change the `name_prefix` |
| Permission denied creating catalog / external location | Service principal isn't a metastore admin (step 3) |
| Workspace group assignment fails: group not found | `DBX_Architect_Lab_Admin` doesn't exist in the account (step 3.3) |

## Running locally instead

```bash
# AWS: any credential source the AWS CLI supports, e.g. SSO
aws sso login --profile <profile>
export AWS_PROFILE=<profile>

# Databricks: the same service principal as CI
export DATABRICKS_ACCOUNT_ID="<databricks-account-id>"
export DATABRICKS_CLIENT_ID="<service-principal-client-id>"
export DATABRICKS_CLIENT_SECRET="<service-principal-secret>"
export DATABRICKS_METASTORE_ID="<metastore-id>"
export DEPLOY_SP_APPLICATION_ID="$DATABRICKS_CLIENT_ID"

cd live/dev/workspace && terragrunt plan
```

To run `workspace-bootstrap` as your own Databricks user instead of the service principal, unset
`DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`, run
`databricks auth login --host <workspace-url>`, and set `DATABRICKS_AUTH_TYPE=databricks-cli`. Your user needs the
same permissions as the service principal (workspace admin, metastore admin). The `workspace` and `metastore`
stacks use the account-level provider, which needs account admin. The simplest option is to keep using the
service principal for them.

On Windows PowerShell, use `$env:NAME = "value"` instead of `export`.
