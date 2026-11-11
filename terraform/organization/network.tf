# Red serverless. La VPC, las subredes privadas y las route tables las crea el
# MODULO EXTERNO terraform-aws-modules/vpc/aws 

# Sobre esa red agregamos los Gateway Endpoints y el security group de las Lambdas

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.project
  cidr = var.vpc_cidr
  azs  = [for az in var.azs : "${var.region}${az}"]

  # Solo subredes privadas de aplicacion (una por AZ). Sin publicas, IGW ni NAT
  private_subnets = [for idx, az in var.azs : cidrsubnet(var.vpc_cidr, 8, 11 + idx)]

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = { Name = "${var.project}-app" }
  tags                = local.tags
}

# Gateway Endpoints
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  # Minimo privilegio, solo la tabla del proyecto y las acciones que usa
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:BatchGetItem",
        "dynamodb:TransactWriteItems",
      ]
      Resource = [
        aws_dynamodb_table.this.arn,
        "${aws_dynamodb_table.this.arn}/index/*",
      ]
    }]
  })

  tags = { Name = "${var.project}-dynamodb" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "FotosDeLasSolicitudes"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource  = ["arn:aws:s3:::${local.bucket_media}/*"]
      },
      {
        # La Lambda analytics solo agrega eventos, no lee ni borra
        Sid       = "EventosDeAnalytics"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:PutObject"]
        Resource  = ["arn:aws:s3:::${local.bucket_analytics}/eventos/*"]
      },
    ]
  })

  tags = { Name = "${var.project}-s3" }
}

# Sin reglas de entrada porque nadie inicia conexiones hacia una Lambda. Salida
# solo a los prefix lists de S3 y DynamoDB

resource "aws_security_group" "lambda" {
  name        = "${var.project}-lambda"
  description = "Lambdas de BarrioFix: egress solo a S3 y DynamoDB."
  vpc_id      = module.vpc.vpc_id

  egress {
    description     = "HTTPS a S3 y DynamoDB por los Gateway Endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.s3.prefix_list_id, aws_vpc_endpoint.dynamodb.prefix_list_id]
  }

  tags = { Name = "${var.project}-lambda" }
}
