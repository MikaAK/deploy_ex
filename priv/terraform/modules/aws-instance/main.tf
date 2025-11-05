### EC2 Start ###
#################

# Choose Subnet
resource "random_shuffle" "subnet_id" {
  input        = var.subnet_ids
  result_count = 1
}

data "aws_subnet" "random_subnet" {
  id = random_shuffle.subnet_id.result[0]
}

data "aws_subnets" "az_specific" {
  count = var.instance_availability_zone != null ? 1 : 0

  filter {
    name   = "subnet-id"
    values = var.subnet_ids
  }

  filter {
    name   = "availability-zone"
    values = [var.instance_availability_zone]
  }
}

locals {
  snake_instance_name = lower(replace(var.instance_name, " ", "_"))
  kebab_instance_name = lower(replace(var.instance_name, " ", "-"))
  user_data_env = "echo \"export AWS_USE_DUALSTACK_ENDPOINT=${var.disable_ipv6 ? "false" : "true"}\" >> /etc/profile"
  user_data = <<-EOF
  ${templatefile(
    "${path.module}/cloud_init_data.yaml.tftpl",
    {
      volume_id = var.enable_ebs ? aws_ebs_volume.ec2_ebs[count.index].id : ""
    }
  )}
  ${local.user_data_env}
  EOF
  selected_subnet_id = var.instance_availability_zone != null ? (
    length(data.aws_subnets.az_specific[0].ids) > 0 ?
    data.aws_subnets.az_specific[0].ids[0] :
    random_shuffle.subnet_id.result[0]
  ) : random_shuffle.subnet_id.result[0]
}

data "aws_subnet" "selected_subnet" {
  id = local.selected_subnet_id
}

# Create EC2 Instance
resource "aws_instance" "ec2_instance" {
  # Enable when multi-instancing
  count = var.instance_count

  ami           = var.instance_ami
  instance_type = var.instance_type

  key_name = var.key_pair_key_name

  availability_zone      = coalesce(var.instance_availability_zone, data.aws_subnet.selected_subnet.availability_zone)
  subnet_id              = data.aws_subnet.random_subnet.id
  vpc_security_group_ids = [var.security_group_id]
  private_ip             = var.private_ip

  # Enable both IPv6 and IPv4 (dual-stack)
  ipv6_address_count     = var.disable_ipv6 ? 0 : 1
  associate_public_ip_address = !var.disable_public_ip

  metadata_options {
    http_protocol_ipv6 = "enabled"
  }

  private_dns_name_options {
    hostname_type                     = "resource-name"
    enable_resource_name_dns_a_record = true
    enable_resource_name_dns_aaaa_record = !var.disable_ipv6
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.instance_ebs_primary_size
    encrypted             = false
    delete_on_termination = true # Can use this to not delete root device

    tags = merge({
      Name          = "${var.instance_name}-root-${var.environment}-${count.index}"
      InstanceGroup = local.snake_instance_name
      Group         = var.resource_group
      Environment   = var.environment
      Type          = "Self Made"
    }, var.tags)
  }

  user_data_replace_on_change = true # Can use this to roll instances
  user_data = var.enable_ebs ? file("${path.module}/user_data_init_script.sh") : ""

  tags = merge({
    Name          = "${var.instance_name}-${var.count.index}"
    Group         = var.resource_group
    InstanceGroup = local.snake_instance_name
    Environment   = var.environment
    Type          = "Self Made"
  }, var.tags)
}

### EBS Start ###
#################

# Create EBS Volume
resource "aws_ebs_volume" "ec2_ebs" {
  count = var.enable_ebs ? var.instance_count : 0

  availability_zone = coalesce(var.instance_availability_zone, data.aws_subnet.selected_subnet.availability_zone)
  size              = var.instance_ebs_secondary_size
  snapshot_id       = var.instance_ebs_secondary_snapshot_id
  type              = "gp3"

  tags = merge({
    Name          = "${var.instance_name}-ebs-${var.environment}-${count.index}"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

# Attach EBS Volume
resource "aws_volume_attachment" "ec2_ebs_association" {
  count = var.enable_ebs ? var.instance_count : 0

  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ec2_ebs[count.index].id
  instance_id = element(aws_instance.ec2_instance, count.index).id
}

### Elastic IP Start ###
########################

# Create Elastic IP
resource "aws_eip" "ec2_eip" {
  count = var.enable_eip ? var.instance_count : 0

  domain = "vpc"
  tags = merge({
    Name          = "${var.instance_name}-eip-${var.environment}-${count.index}"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

# Associate Elastic IP to Linux Server
resource "aws_eip_association" "ec2_eip_association" {
  count = var.enable_eip ? var.instance_count : 0

  instance_id   = element(aws_instance.ec2_instance, count.index).id
  allocation_id = aws_eip.ec2_eip[count.index].id
}

### Elastic LB Start ###
########################

# Add Load Balancing if needed and enabled
resource "aws_lb" "ec2_lb" {
  count              = (var.enable_elb && var.instance_count > 1) ? 1 : 0
  name               = "${local.kebab_instance_name}-lb"
  load_balancer_type = "application"

  subnets         = var.subnet_ids
  security_groups = [var.security_group_id]

  tags = merge({
    Name          = "${var.instance_name}-lb"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}


resource "aws_lb_target_group" "ec2_lb_https_target_group" {
  count = (var.enable_elb && var.enable_elb_https && var.instance_count > 1) ? 1 : 0
  name  = "${local.kebab_instance_name}-lb-https-tg-${var.environment}"
  vpc_id   = data.aws_subnet.random_subnet.vpc_id
  protocol = "TCP"
  port     = 443

  dynamic "health_check" {
    for_each = var.elb_health_check_path != "" ? [1] : []

    content {
      path                = var.elb_health_check_path
      protocol            = "HTTPS"
      interval            = var.elb_health_check_interval
      timeout             = var.elb_health_check_timeout
      healthy_threshold   = var.elb_health_check_healthy_threshold
      unhealthy_threshold = var.elb_health_check_unhealthy_threshold
      matcher             = var.elb_health_check_https_matcher
    }
  }

  tags = merge({
    Name          = "${local.kebab_instance_name}-https-lb-tg-${var.environment}"
    InstanceGroup = "${local.snake_instance_name}_${var.environment}"
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_lb_target_group" "ec2_lb_target_group" {
  count = (var.enable_elb && var.instance_count > 1) ? 1 : 0
  name  = "${local.kebab_instance_name}-lb-tg"

  vpc_id   = data.aws_subnet.random_subnet.vpc_id
  protocol = "HTTP"
  port     = var.elb_instance_port

  dynamic "health_check" {
    for_each = var.elb_health_check_path != "" ? [1] : []

    content {
      path                = var.elb_health_check_path
      protocol            = "HTTP"
      interval            = var.elb_health_check_interval
      timeout             = var.elb_health_check_timeout
      healthy_threshold   = var.elb_health_check_healthy_threshold
      unhealthy_threshold = var.elb_health_check_unhealthy_threshold
      matcher             = var.elb_health_check_matcher
    }
  }

  tags = merge({
    Name          = "${var.instance_name}-http-lb-tg"
    InstanceGroup = local.kebab_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_lb_target_group_attachment" "ec2_lb_https_target_group_attachment" {
  count = (var.enable_elb && var.enable_elb_https && var.instance_count > 1) ? var.instance_count : 0
  target_group_arn = aws_lb_target_group.ec2_lb_https_target_group[0].arn
  target_id        = aws_instance.ec2_instance[count.index].id
  port             = 443
}

resource "aws_lb_target_group_attachment" "ec2_lb_target_group_attachment" {
  count = (var.enable_elb && var.instance_count > 1) ? var.instance_count : 0

  target_group_arn = aws_lb_target_group.ec2_lb_target_group[0].arn
  target_id        = aws_instance.ec2_instance[count.index].id
  port             = var.elb_instance_port
}

resource "aws_lb_listener" "ec2_lb_https_listener" {
  count = (var.enable_elb && var.enable_elb_https && var.instance_count > 1) ? var.instance_count : 0
  load_balancer_arn = aws_lb.ec2_lb[0].arn
  port              = 443
  protocol          = aws_lb_target_group.ec2_lb_https_target_group[0].protocol
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_lb_https_target_group[0].arn
  }
}

resource "aws_lb_listener" "ec2_lb_listener" {
  count = (var.enable_elb && var.instance_count > 1) ? var.instance_count : 0

  load_balancer_arn = aws_lb.ec2_lb[0].arn
  port              = var.elb_port
  protocol          = aws_lb_target_group.ec2_lb_target_group[0].protocol

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_lb_target_group[0].arn
  }
}
