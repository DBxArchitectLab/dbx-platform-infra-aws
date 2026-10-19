# Databricks on AWS Private Workspace Deployment

Part of **DBX Architect Lab**, an enterprise Databricks platform built in public:
[YouTube](https://www.youtube.com/@DBxArchitectLab) ·
[LinkedIn](https://www.linkedin.com/in/DBxArchitectLab) ·
[GitHub](https://github.com/DBxArchitectLab)

This repository provisions Databricks workspaces on AWS with:

- a customer-managed VPC per environment (name and CIDR from config)
- cluster subnets in two or more availability zones
- a NAT gateway for outbound internet access (optional, on by default)
- back-end PrivateLink: workspace REST API and secure cluster connectivity relay VPC endpoints (optional, Enterprise tier)
- S3 gateway endpoint, plus STS and Kinesis interface endpoints when PrivateLink is on
- secure cluster connectivity (no public IPs on cluster nodes)
- with PrivateLink on, optional public access to the workspace UI and API (`private_link.public_access_enabled`)
- a cross-account IAM role and an S3 root bucket per workspace
- a Unity Catalog metastore (provisioned by a dedicated stack)
- Unity Catalog metastore assignment
- workspace admin assignment for an account-level group
- workspace bootstrap (S3 bucket, IAM role, storage credential, external location, catalog, cluster policies, secret
  scope, validation notebook)

As configured, PrivateLink is **off** in dev, uat and prod (`private_link.enabled: false` in `live/<env>/config.yaml`),
so the workspaces run on the Premium tier: clusters reach the control plane through the NAT gateway, and the workspace
UI and API are reachable from the internet. Set it to `true` on the Enterprise tier.

## Deployment pattern

- Terraform modules contain provisioning logic
- Terragrunt orchestrates deployments
- `live/root.hcl` generates the S3 state backend and the providers for every stack
- `live/metastore/config.yaml` and `live/<env>/config.yaml` store each stack's inputs; `live/<env>/env.hcl` loads
  `config.yaml`
- `live/<env>/workspace-bootstrap/*-config.yaml` describe the bootstrap objects (bucket, external location,
  catalog, cluster policies, secret scope)

## What this creates

- **Metastore layer (`live/metastore` → `modules/metastore`)**
  - Databricks Unity Catalog metastore (account-level, one per region), owned by `DBX_Architect_Lab_Admin`
  - Optional metastore-level storage (`storage_root` plus an IAM role ARN)

- **Workspace layer (`live/<env>/workspace` → `modules/dbx_workspace_private`)**
  - VPC, subnets, route tables and security groups; internet gateway and NAT gateway when `nat_gateway_enabled`
  - VPC endpoints (S3; STS, Kinesis, Databricks workspace and relay when PrivateLink is on)
  - Databricks network configuration (plus VPC endpoint registrations and private access settings when PrivateLink
    is on)
  - Cross-account IAM role and Databricks credential configuration
  - S3 root bucket and Databricks storage configuration
  - Databricks workspace (E2)
  - Unity Catalog metastore assignment
  - Workspace admin assignment for an account-level group

- **Workspace bootstrap layer (`live/<env>/workspace-bootstrap` → `modules/workspace_bootstrap`)**
  - S3 bucket for Unity Catalog data (`s3-storage-config.yaml`)
  - IAM role, storage credential, external location and its grants (`external-location-config.yaml`)
  - Catalog and grants (`catalog-config.yaml`), with managed storage at `s3://<bucket>/managed/<catalog>/`
  - Cluster policies (`cluster-policy-config.yaml`)
  - Secret scope (`secret-scope-config.yaml`)
  - Validation notebook `/Shared/platform/workspace-bootstrap-validation`, with this environment's expected values
    in `/Shared/platform/workspace-bootstrap-validation.json`
    (`modules/workspace_bootstrap/notebooks/workspace-bootstrap-validation.py`; see
    [DEPLOYMENT.md section 6](DEPLOYMENT.md#6-verify))

dev, uat and prod share one metastore. The catalog, storage credential and external location are created in
isolated mode, so each is bound only to its own environment's workspace.

## Identity

- **Cross-account role:** Databricks assumes it to manage the workspace's EC2 resources. It trusts the Databricks
  AWS account with your Databricks account ID as the external ID.
- **Unity Catalog role:** the storage credential's IAM role trusts the Unity Catalog master role, with the external
  ID that Databricks generates for the credential, and itself. The credential is therefore created first (with
  validation skipped), then the role; the external location checks access once the role exists.
- **Deployment:** GitHub Actions reaches AWS through OIDC (no long-lived keys) and Databricks as a service principal
  with an OAuth secret.

## What this does not create

- The Terraform state bucket
- The GitHub OIDC provider and deployment IAM role
- The Databricks account, service principal and admin group
- UC schemas
- Clusters and SQL warehouses: `cluster-config.yaml` and `sql-warehouse-config.yaml` are present, but their modules
  are commented out in `modules/workspace_bootstrap/main.tf`

## Prerequisites

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full setup and deployment steps, and
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) for diagnosis scripts and fixes for known issues.
`scripts/setup-aws-prerequisites.sh` creates the AWS prerequisites and `scripts/preflight-check.sh` checks the
whole setup. In short:

- AWS account with an S3 bucket `dbx-architect-lab-tfstate-<aws-account-id>` (us-east-2) for Terraform state
- IAM role trusted by GitHub OIDC for this repo's `dev`/`uat`/`prod` environments
- Databricks account on AWS (Premium; Enterprise if PrivateLink is enabled)
- Databricks service principal with an OAuth secret, as account admin
- Databricks account group `DBX_Architect_Lab_Admin` containing the service principal (as the metastore owner, the
  group makes the service principal a metastore admin, which bootstrap needs)
- Each workspace in the same region as the metastore (`us-east-2` in this configuration)

Tools: Terraform >= 1.10 and Terragrunt (CI uses Terraform 1.14.6 and Terragrunt 0.99.4). Providers: `aws` ~> 6.0;
`databricks` >= 1.105.0; `time` ~> 0.12.

## Authentication

| Provider | CI (GitHub Actions) | Local |
| --- | --- | --- |
| AWS | OIDC → `AWS_ROLE_ARN` (aws-actions/configure-aws-credentials) | AWS CLI profile / SSO (`AWS_PROFILE`) |
| Databricks account (`https://accounts.cloud.databricks.com`) | Service principal OAuth M2M: `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` | Same environment variables |
| Databricks workspace (workspace-bootstrap) | Same service principal (workspace admin through `DBX_Architect_Lab_Admin`) | Same, or unset `DATABRICKS_CLIENT_ID`/`DATABRICKS_CLIENT_SECRET`, run `databricks auth login` and set `DATABRICKS_AUTH_TYPE=databricks-cli` |

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

Run `terragrunt plan` before each apply. From the repository root, after exporting the environment variables above
(see [DEPLOYMENT.md, Running locally instead](DEPLOYMENT.md#running-locally-instead)):

```bash
# 1. Metastore (once per region), then set DATABRICKS_METASTORE_ID to its metastore_id output
(cd live/metastore && terragrunt apply)

# 2. Workspace
(cd live/dev/workspace && terragrunt apply)

# 3. Workspace bootstrap (needs the workspace stack applied)
(cd live/dev/workspace-bootstrap && terragrunt apply)
```

Repeat steps 2 and 3 for `uat` and `prod`.

### GitHub Actions

The **Terragrunt Deploy Stacks** workflow (`.github/workflows/terragrunt-deploy.yml`) is run manually (workflow
dispatch). Pick a stack (`metastore`, or `<env>-dbxarchitectlab-workspace` /
`<env>-dbxarchitectlab-workspace-bootstrap` for `dev`, `uat` or `prod`) and an action (`validate`, `plan`, `apply`
or `destroy`). The job runs in the matching GitHub environment (`prod-*` → `prod`, `uat-*` → `uat`, everything
else, including `metastore` → `dev`) and reads its secrets from there.

Each of the `dev`, `uat` and `prod` environments needs these secrets:

| Secret | Value |
| --- | --- |
| `AWS_ROLE_ARN` | ARN of the IAM role GitHub Actions assumes through OIDC |
| `DATABRICKS_ACCOUNT_ID` | Databricks account ID |
| `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` | The deployment service principal's OAuth credentials |
| `DATABRICKS_METASTORE_ID` | The metastore stack's `metastore_id` output; a placeholder until the metastore exists |

`apply` and `destroy` run with `-auto-approve`; add required reviewers to the `prod` environment if you want a
manual gate.

### Destroy

Destroy in reverse order: `<env>-dbxarchitectlab-workspace-bootstrap`, then `<env>-dbxarchitectlab-workspace` for
each environment, then `metastore` once no environment uses it.

- A workspace destroy pauses for 3 minutes after the workspace is deleted, because Databricks deletes it
  asynchronously and keeps its network, storage and credential configurations attached for a short time.
- `force_destroy` is on for the root buckets, the Unity Catalog bucket, catalog and external location, and the
  metastore, so destroy deletes their data too.
- Apply also includes short waits for IAM to propagate: 60 seconds after the cross-account role is created, and 30
  seconds after the Unity Catalog role.

## DBX Architect Lab

This repository is part of **DBX Architect Lab**: one enterprise Databricks platform on Azure, AWS and Google
Cloud, built in public. The videos walk through the architecture and the deployment step by step.

- YouTube: [youtube.com/@DBxArchitectLab](https://www.youtube.com/@DBxArchitectLab)
- LinkedIn: [linkedin.com/in/DBxArchitectLab](https://www.linkedin.com/in/DBxArchitectLab)
- GitHub: [github.com/DBxArchitectLab](https://github.com/DBxArchitectLab)

## Contributing and license

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under the
[Apache License 2.0](LICENSE); see also [NOTICE](NOTICE).
