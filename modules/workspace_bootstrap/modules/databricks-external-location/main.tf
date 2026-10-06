data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id
  # The role ARN is known before the role exists: the role's trust policy needs the storage credential's
  # external ID, so the credential is created first and the role second.
  iam_role_arn = "arn:aws:iam::${local.aws_account_id}:role/${var.iam_role_name}"
  external_url = "s3://${var.bucket_name}/"
  # Unity Catalog owners can manage the object; without this, grant-only MANAGE may apply after EL updates in the same run and Terraform still fails to modify the location.
  external_location_owner = coalesce(var.external_location_owner, var.external_location_grant_principals[0])
}

resource "databricks_storage_credential" "this" {
  name = var.storage_credential_name

  # Required when the credential is bound to external locations (Unity Catalog API otherwise rejects in-place updates).
  force_update = true
  # The IAM role is created after the credential; the external location validates access once it exists.
  skip_validation = true
  # Only usable from this environment's workspace (see databricks_workspace_binding below).
  isolation_mode = "ISOLATION_MODE_ISOLATED"

  aws_iam_role {
    role_arn = local.iam_role_arn
  }
}

# Trust policy: the Unity Catalog master role (with this credential's external ID) and the role itself.
data "databricks_aws_unity_catalog_assume_role_policy" "this" {
  aws_account_id = local.aws_account_id
  role_name      = var.iam_role_name
  external_id    = databricks_storage_credential.this.aws_iam_role[0].external_id
}

# Read/write access to the bucket.
data "databricks_aws_unity_catalog_policy" "this" {
  aws_account_id = local.aws_account_id
  bucket_name    = var.bucket_name
  role_name      = var.iam_role_name
}

resource "aws_iam_role" "this" {
  name               = var.iam_role_name
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.this.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.iam_role_name}-s3"
  role   = aws_iam_role.this.id
  policy = data.databricks_aws_unity_catalog_policy.this.json
}

# New IAM roles take a few seconds to become assumable; creating the external location too early fails validation.
resource "time_sleep" "iam_propagation" {
  create_duration = "30s"

  depends_on = [aws_iam_role_policy.this]
}

resource "databricks_external_location" "this" {
  name            = var.external_location_name
  url             = local.external_url
  credential_name = databricks_storage_credential.this.name
  comment         = "Bootstrap external location."
  owner           = local.external_location_owner
  force_update    = true
  isolation_mode  = "ISOLATION_MODE_ISOLATED"

  depends_on = [time_sleep.iam_propagation]
}

# The metastore is shared by dev/uat/prod; bind the credential and location to this environment's workspace only.
resource "databricks_workspace_binding" "storage_credential" {
  securable_name = databricks_storage_credential.this.name
  securable_type = "storage_credential"
  workspace_id   = var.workspace_id
  binding_type   = "BINDING_TYPE_READ_WRITE"
}

resource "databricks_workspace_binding" "external_location" {
  securable_name = databricks_external_location.this.name
  securable_type = "external_location"
  workspace_id   = var.workspace_id
  binding_type   = "BINDING_TYPE_READ_WRITE"
}

resource "databricks_grants" "external_location" {
  count = var.enable_external_location_grants ? 1 : 0

  external_location = databricks_external_location.this.name

  dynamic "grant" {
    for_each = toset(var.external_location_grant_principals)
    content {
      principal  = grant.value
      privileges = var.external_location_grant_privileges
    }
  }

  depends_on = [databricks_external_location.this]
}
