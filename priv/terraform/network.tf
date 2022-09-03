data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.14.2"

  cidr = "10.0.0.0/16"

  azs = data.aws_availability_zones.available.names

  private_subnets = ["10.0.101.0/24"]
  public_subnets  = ["10.0.1.0/24"]

  map_public_ip_on_launch = false
  enable_dns_hostnames = true
  enable_dns_support   = true
}

module "app_security_group" {
  source  = "terraform-aws-modules/security-group/aws//modules/web"
  version = "4.9.0"

  name        = "LE-sg-${var.project_name}-${var.environment}"
  description = "Security group for web-servers with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  auto_ingress_rules = []
  ingress_rules      = ["http-80-tcp", "https-443-tcp", "ssh-tcp"]

  ingress_cidr_blocks = ["0.0.0.0/0"] # concat(module.vpc.public_subnets_cidr_blocks, ["0.0.0.0/0"])
}

