# Databricks on AWS Private Workspace Deployment

This repository provisions Databricks workspaces on AWS with:

- a customer-managed VPC per environment (name and CIDR from config)
- cluster subnets in two or more availability zones
- a NAT gateway for outbound internet access (optional)
- back-end PrivateLink: workspace REST API and secure cluster connectivity relay VPC endpoints (optional, Enterprise tier)
- S3 gateway endpoint, plus STS and Kinesis interface endpoints when PrivateLink is on
- secure cluster connectivity (no public IPs on cluster nodes)
- optional public access to the workspace (controlled by config)
- a cross-account IAM role and an S3 root bucket per workspace
- a Unity Catalog metastore (provisioned by a dedicated stack)
- Unity Catalog metastore assignment
- workspace admin assignment for an account-level group
- workspace bootstrap (S3 bucket, IAM role, storage credential, external location, catalog, cluster policies, secret scope, optional clusters and SQL warehouses)

## Deployment pattern

- Terraform modules contain provisioning logic
- Terragrunt orchestrates deployments
- config.yaml stores environment-specific inputs

## What this creates

- **Metastore layer (`live/metastore` → `modules/metastore`)**
  - Databricks Unity Catalog metastore (account-level, one per region)
  - Optional metastore-level storage (`storage_root` plus an IAM role ARN)

- **Workspace layer (`live/<env>/workspace` → `modules/dbx_workspace_private`)**
  - VPC, subnets, route tables, internet + NAT gateway, security groups
  - VPC endpoints (S3; STS, Kinesis, Databricks workspace and relay when PrivateLink is on)
  - Databricks network configuration, VPC endpoint registrations, private access settings
  - Cross-account IAM role and Databricks credential configuration
  - S3 root bucket and Databricks storage configuration
  - Databricks workspace (E2)
  - Unity Catalog metastore assignment
  - Workspace admin assignment for an account-level group

- **Workspace bootstrap layer (`live/<env>/workspace-bootstrap` → `modules/workspace_bootstrap`)**
  - S3 bucket for Unity Catalog data (`s3-storage-config.yaml`)
  - IAM role, storage credential and external location (`external-location-config.yaml`)
  - Catalog and grants (`catalog-config.yaml`)
  - Cluster policies (`cluster-policy-config.yaml`)
  - Secret scope (`secret-scope-config.yaml`)
  - Clusters and SQL warehouses (`cluster-config.yaml`, `sql-warehouse-config.yaml`; modules are commented out in `modules/workspace_bootstrap/main.tf`)

## What this does not create

- The Terraform state bucket
- The GitHub OIDC provider and deployment IAM role
- The Databricks account, service principal and admin group
- UC schemas

## Prerequisites

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full setup and deployment steps. In short:

- AWS account with an S3 bucket `dbx-architect-lab-tfstate-<aws-account-id>` (us-east-1) for Terraform state
- IAM role trusted by GitHub OIDC for this repo's `dev`/`uat`/`prod` environments
- Databricks account on AWS (Enterprise tier if PrivateLink is enabled)
- Databricks service principal with an OAuth secret, as account admin
- Databricks account group `DBX_Architect_Lab_Admin` containing the service principal

## Authentication

| Provider | CI (GitHub Actions) | Local |
| --- | --- | --- |
| AWS | OIDC → `AWS_ROLE_ARN` (aws-actions/configure-aws-credentials) | AWS CLI profile / SSO (`AWS_PROFILE`) |
| Databricks account (`https://accounts.cloud.databricks.com`) | Service principal OAuth M2M: `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` | Same environment variables |
| Databricks workspace (workspace-bootstrap) | Same service principal (workspace admin through `DBX_Architect_Lab_Admin`) | Same, or `databricks auth login` + `DATABRICKS_AUTH_TYPE=databricks-cli` |

### Required environment variables

| Variable | Used for |
| --- | --- |
| `DATABRICKS_ACCOUNT_ID` | Databricks account-level provider and account resources |
| `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` | Databricks authentication (service principal OAuth) |
| `DATABRICKS_METASTORE_ID` | Unity Catalog metastore assigned to the workspace (`*/workspace` stacks and their dependents) |
| `DEPLOY_SP_APPLICATION_ID` | Application ID of the deployment service principal, granted on the catalog and external location (`*/workspace-bootstrap` stacks). In GitHub Actions it comes from `DATABRICKS_CLIENT_ID`. |

AWS credentials come from the standard AWS credential chain. The AWS account ID is looked up at runtime
(`get_aws_account_id()`) and appended to bucket names to keep them globally unique.

## Run

```bash
# 1. Metastore (once per region), then set DATABRICKS_METASTORE_ID to its metastore_id output
cd live/metastore && terragrunt apply

# 2. Workspace
cd live/dev/workspace && terragrunt apply

# 3. Workspace bootstrap (needs the workspace stack applied)
cd live/dev/workspace-bootstrap && terragrunt apply
```

Run `terragrunt plan` first in each directory.

### GitHub Actions

`.github/workflows/terragrunt-deploy.yml` is run manually (workflow dispatch). Pick a stack (`metastore`,
`dev-*`, `uat-*` or `prod-*`) and an action (`validate`, `plan`, `apply` or `destroy`). The job runs in the
matching GitHub environment (`prod-*` → `prod`, `uat-*` → `uat`, everything else → `dev`) and reads its
secrets from there.
