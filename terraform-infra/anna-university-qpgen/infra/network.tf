# Private network only: no internet gateway and no NAT. Lambda reaches AWS
# services through VPC endpoints and OpenSearch is reachable only from inside.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Security groups ----------------------------------------------------------------------

resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda"
  description = "Lambda functions"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "endpoints" {
  name        = "${local.name}-endpoints"
  description = "Interface VPC endpoints"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "opensearch" {
  name        = "${local.name}-opensearch"
  description = "OpenSearch domain"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_lambda" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS from Lambda"
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_from_lambda" {
  security_group_id            = aws_security_group.opensearch.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS from Lambda"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_endpoints" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS to interface endpoints"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_opensearch" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.opensearch.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS to OpenSearch"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_gateway_endpoints" {
  for_each = {
    s3       = aws_vpc_endpoint.gateway["s3"].prefix_list_id
    dynamodb = aws_vpc_endpoint.gateway["dynamodb"].prefix_list_id
  }

  security_group_id = aws_security_group.lambda.id
  prefix_list_id    = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS to the ${each.key} gateway endpoint"
}

# --- VPC endpoints ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "gateway" {
  for_each = toset(["s3", "dynamodb"])

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.name}-${each.key}" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(["bedrock-runtime", "sqs", "logs", "xray"])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-${each.key}" }
}
