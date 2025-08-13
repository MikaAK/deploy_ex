data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

locals {
  project_name = lower(replace(var.project_name, "_", "-"))

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  name = "${local.project_name}-vpc"

  cidr = local.vpc_cidr

  map_public_ip_on_launch = !var.disable_ipv6 || var.enable_ipv4

  # Enable IPv6
  enable_ipv6                                    = !var.disable_ipv6
  public_subnet_assign_ipv6_address_on_creation  = !var.disable_ipv6
  private_subnet_assign_ipv6_address_on_creation = !var.disable_ipv6

  # Create IPv6 CIDR blocks for the VPC and subnets
  create_egress_only_igw = !var.disable_ipv6

  # Enable IPv6 CIDR blocks for subnets
  private_subnet_ipv6_prefixes  = var.disable_ipv6 ? [] : [0, 1, 2]
  public_subnet_ipv6_prefixes   = var.disable_ipv6 ? [] : [3, 4, 5]
  database_subnet_ipv6_prefixes = var.disable_ipv6 ? [] : [6, 7, 8]

  # Allow IPv6 DNS resolution for IPv4 addresses
  private_subnet_enable_dns64 = !var.disable_ipv6
  public_subnet_enable_dns64  = !var.disable_ipv6

  # This makes the database publicly accessible (Not Recommended)
  create_database_internet_gateway_route = false

  azs = data.aws_availability_zones.available.names

  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]

  enable_dns_hostnames = true
  enable_dns_support   = true

  manage_default_network_acl    = false
  manage_default_route_table    = false
  manage_default_security_group = false
  manage_default_vpc            = false

  igw_tags = {
    Name = "${local.project_name}-igw"
  }

  default_route_table_tags = {
    Name = "${local.project_name}-default-rt"
  }

  private_route_table_tags = {
    Name = "${local.project_name}-private-rt"
  }

  public_route_table_tags = {
    Name = "${local.project_name}-public-rt"
  }
}
resource "aws_ec2_tag" "eigw_name" {
  # Only create if IPv6 is enabled
  count = !var.disable_ipv6 ? 1 : 0

  resource_id = module.vpc.egress_only_internet_gateway_id
  key         = "Name"
  value       = "${local.project_name}-eigw"
}

module "app_security_group" {
  source  = "terraform-aws-modules/security-group/aws//modules/web"
  version = "5.1.0"

  name        = "${local.project_name}-sg"
  description = "Security group for web-servers with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  auto_ingress_rules = []
  ingress_rules      = ["http-80-tcp", "https-443-tcp", "ssh-tcp"]

  # Add IPv6 CIDR blocks to security group
  ingress_cidr_blocks      = ["0.0.0.0/0"]
  ingress_ipv6_cidr_blocks = ["::/0"]
  # Only allow access from the public subnets
  # ingress_cidr_blocks      = module.vpc.public_subnets_cidr_blocks
  # ingress_ipv6_cidr_blocks = module.vpc.public_subnets_ipv6_cidr_blocks
}
