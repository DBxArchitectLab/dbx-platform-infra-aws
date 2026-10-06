# IAM role that the Databricks control plane assumes to launch cluster instances in this AWS account.
data "databricks_aws_assume_role_policy" "this" {
  provider = databricks.account

  external_id = var.databricks_account_id
}

# Permissions for a customer-managed VPC.
data "databricks_aws_crossaccount_policy" "this" {
  provider = databricks.account

  policy_type = "customer"
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.this.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}

# New IAM roles take a few seconds to become usable; registering the credential too early fails validation.
resource "time_sleep" "iam_propagation" {
  create_duration = "30s"

  depends_on = [aws_iam_role_policy.this]
}

resource "databricks_mws_credentials" "this" {
  provider = databricks.account

  credentials_name = "${var.role_name}-credentials"
  role_arn         = aws_iam_role.this.arn

  depends_on = [time_sleep.iam_propagation]
}
