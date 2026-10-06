locals {
  az_count = length(var.availability_zones)
}

# --- VPC and subnets --------------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.vpc_name })
}

# Cluster subnets. Databricks requires at least two, in different availability zones.
resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags              = merge(var.tags, { Name = "${var.vpc_name}-private-${var.availability_zones[count.index]}" })
}

# Subnets for the interface VPC endpoints (Databricks PrivateLink, STS, Kinesis).
resource "aws_subnet" "privatelink" {
  count = var.private_link_enabled ? local.az_count : 0

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.privatelink_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags              = merge(var.tags, { Name = "${var.vpc_name}-privatelink-${var.availability_zones[count.index]}" })
}

# Public subnet that only hosts the NAT gateway.
resource "aws_subnet" "public" {
  count = var.nat_gateway_enabled ? 1 : 0

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zones[0]
  tags              = merge(var.tags, { Name = "${var.vpc_name}-public" })
}

# --- Internet egress (NAT) --------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  count = var.nat_gateway_enabled ? 1 : 0

  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.vpc_name}-igw" })
}

resource "aws_route_table" "public" {
  count = var.nat_gateway_enabled ? 1 : 0

  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.vpc_name}-public" })

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
}

resource "aws_route_table_association" "public" {
  count = var.nat_gateway_enabled ? 1 : 0

  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_eip" "nat" {
  count = var.nat_gateway_enabled ? 1 : 0

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.vpc_name}-nat" })
}

resource "aws_nat_gateway" "this" {
  count = var.nat_gateway_enabled ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(var.tags, { Name = "${var.vpc_name}-nat" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.vpc_name}-private" })
}

resource "aws_route" "private_nat" {
  count = var.nat_gateway_enabled ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "privatelink" {
  count = var.private_link_enabled ? local.az_count : 0

  subnet_id      = aws_subnet.privatelink[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Security groups --------------------------------------------------------------------------------

# Workspace (cluster) security group, with the rules Databricks requires for a customer-managed VPC.
resource "aws_security_group" "workspace" {
  name        = "${var.vpc_name}-workspace"
  description = "Databricks workspace clusters"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.vpc_name}-workspace" })

  ingress {
    description = "All traffic between cluster nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All traffic between cluster nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  dynamic "egress" {
    for_each = {
      "Databricks infrastructure, cloud data sources and library repositories" = [443, 443]
      "Databricks control plane (FIPS)"                                        = [2443, 2443]
      "Legacy Hive metastore"                                                  = [3306, 3306]
      "Secure cluster connectivity relay"                                      = [6666, 6666]
      "Databricks control plane and Unity Catalog"                             = [8443, 8451]
      "DNS"                                                                    = [53, 53]
    }
    content {
      description = egress.key
      from_port   = egress.value[0]
      to_port     = egress.value[1]
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "endpoints" {
  count = var.private_link_enabled ? 1 : 0

  name        = "${var.vpc_name}-endpoints"
  description = "Interface VPC endpoints used by the Databricks workspace"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.vpc_name}-endpoints" })

  dynamic "ingress" {
    for_each = {
      "HTTPS (REST API, STS, Kinesis)"             = [443, 443]
      "Databricks control plane (FIPS)"            = [2443, 2443]
      "Secure cluster connectivity relay"          = [6666, 6666]
      "Databricks control plane and Unity Catalog" = [8443, 8451]
    }
    content {
      description     = ingress.key
      from_port       = ingress.value[0]
      to_port         = ingress.value[1]
      protocol        = "tcp"
      security_groups = [aws_security_group.workspace.id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- VPC endpoints ----------------------------------------------------------------------------------

# Gateway endpoint: S3 traffic (root bucket, Unity Catalog storage, runtime artifacts) stays on AWS.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(var.tags, { Name = "${var.vpc_name}-s3" })
}

resource "aws_vpc_endpoint" "aws_services" {
  for_each = var.private_link_enabled ? toset(["sts", "kinesis-streams"]) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.privatelink[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.vpc_name}-${each.key}" })
}

# Back-end PrivateLink: workspace REST API and secure cluster connectivity relay.
resource "aws_vpc_endpoint" "workspace" {
  count = var.private_link_enabled ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = var.workspace_vpce_service
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.privatelink[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.vpc_name}-databricks-workspace" })
}

resource "aws_vpc_endpoint" "relay" {
  count = var.private_link_enabled ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = var.relay_vpce_service
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.privatelink[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.vpc_name}-databricks-relay" })
}

# --- Databricks account registrations ---------------------------------------------------------------

resource "databricks_mws_vpc_endpoint" "workspace" {
  count    = var.private_link_enabled ? 1 : 0
  provider = databricks.account

  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.workspace[0].id
  vpc_endpoint_name   = "${var.vpc_name}-workspace"
  region              = var.region
}

resource "databricks_mws_vpc_endpoint" "relay" {
  count    = var.private_link_enabled ? 1 : 0
  provider = databricks.account

  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.relay[0].id
  vpc_endpoint_name   = "${var.vpc_name}-relay"
  region              = var.region
}

resource "databricks_mws_networks" "this" {
  provider = databricks.account

  account_id         = var.databricks_account_id
  network_name       = "${var.vpc_name}-network"
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.workspace.id]

  dynamic "vpc_endpoints" {
    for_each = var.private_link_enabled ? [1] : []
    content {
      rest_api        = [databricks_mws_vpc_endpoint.workspace[0].vpc_endpoint_id]
      dataplane_relay = [databricks_mws_vpc_endpoint.relay[0].vpc_endpoint_id]
    }
  }

  lifecycle {
    precondition {
      condition     = var.nat_gateway_enabled || var.private_link_enabled
      error_message = "Clusters need a path to the Databricks control plane: enable nat_gateway_enabled, private_link_enabled, or both."
    }

    precondition {
      condition     = length(var.private_subnet_cidrs) == length(var.availability_zones)
      error_message = "private_subnet_cidrs must have one CIDR per availability zone."
    }

    precondition {
      condition     = !var.private_link_enabled || (length(var.privatelink_subnet_cidrs) == length(var.availability_zones) && var.workspace_vpce_service != null && var.relay_vpce_service != null)
      error_message = "With private_link_enabled, set privatelink_subnet_cidrs (one per availability zone), workspace_vpce_service and relay_vpce_service."
    }
  }

  depends_on = [
    aws_route_table_association.private,
    aws_route.private_nat,
  ]
}

resource "databricks_mws_private_access_settings" "this" {
  count    = var.private_link_enabled ? 1 : 0
  provider = databricks.account

  private_access_settings_name = "${var.vpc_name}-pas"
  region                       = var.region
  public_access_enabled        = var.public_access_enabled
  private_access_level         = "ACCOUNT"
}
