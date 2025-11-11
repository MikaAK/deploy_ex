### Data Sources ###
####################

data "aws_caller_identity" "current" {}

# Fetch custom AMI from SSM if available, otherwise use base AMI
data "external" "custom_ami" {
  program = ["bash", "${path.module}/scripts/get_ami_from_ssm.sh"]
  
  query = {
    param_name   = "/deploy_ex/${var.environment}/${replace(lower(var.instance_name), "-", "_")}/latest_ami"
    fallback_ami = var.instance_ami
  }
}

locals {
  snake_instance_name = replace(lower(var.instance_name), "-", "_")
  kebab_instance_name = replace(lower(var.instance_name), "_", "-")
  
  # Use custom AMI if available and different from base AMI
  use_custom_ami = data.external.custom_ami.result.ami_id != var.instance_ami
  selected_ami   = data.external.custom_ami.result.ami_id
  
  # Calculate the subnet ID to use based on instance count
  selected_subnet_id = var.instance_count == 1 ? (
    length(var.subnet_ids) > 0 ? var.subnet_ids[0] : ""
  ) : random_shuffle.subnet_id.result[0]
  
  enable_load_balancer = var.enable_elb && var.instance_count > 1
  enable_https_load_balancer = var.enable_elb && var.enable_elb_https && var.instance_count > 1
}

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

data "aws_subnet" "selected_subnet" {
  id = local.selected_subnet_id
}

# Create EC2 Instance
resource "aws_instance" "ec2_instance" {
  # Enable when multi-instancing, disable when autoscaling
  count = var.enable_autoscaling ? 0 : var.instance_count

  ami           = local.selected_ami
  instance_type = var.instance_type

  key_name = var.key_pair_key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name

  availability_zone      = coalesce(var.instance_availability_zone, data.aws_subnet.selected_subnet.availability_zone)
  subnet_id              = local.selected_subnet_id
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
      Name          = "${local.kebab_instance_name}-root-${var.environment}-${count.index}"
      InstanceGroup = local.snake_instance_name
      Group         = var.resource_group
      Environment   = var.environment
      Type          = "Self Made"
    }, var.tags)
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/cloud_init_data.yaml.tftpl", {
    app_name    = local.snake_instance_name
    environment = var.environment
    app_port    = var.app_port
    volume_id   = var.enable_ebs ? aws_ebs_volume.ec2_ebs[count.index].id : ""
  })

  tags = merge({
    Name          = "${local.kebab_instance_name}-${count.index}"
    Group         = var.resource_group
    InstanceGroup = local.snake_instance_name
    Environment   = var.environment
    Type          = "Self Made"
  }, var.tags)
}

### EBS Start ###
#################

# Create EBS Volume
# For autoscaling: creates a pool of volumes equal to max_size
# For static instances: creates volumes equal to instance_count
resource "aws_ebs_volume" "ec2_ebs" {
  count = var.enable_ebs ? (var.enable_autoscaling ? var.autoscaling_max_size : var.instance_count) : 0

  availability_zone = coalesce(var.instance_availability_zone, data.aws_subnet.selected_subnet.availability_zone)
  size              = var.instance_ebs_secondary_size
  snapshot_id       = var.instance_ebs_secondary_snapshot_id
  type              = "gp3"

  tags = merge({
    Name          = "${local.kebab_instance_name}-ebs-${var.environment}-${count.index}"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
    AutoscalingPool = var.enable_autoscaling ? "true" : "false"
  }, var.tags)
}

# Attach EBS Volume
resource "aws_volume_attachment" "ec2_ebs_association" {
  count = var.enable_autoscaling ? 0 : (var.enable_ebs ? var.instance_count : 0)

  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ec2_ebs[count.index].id
  instance_id = element(aws_instance.ec2_instance, count.index).id
}

### Elastic IP Start ###
########################

# Create Elastic IP
resource "aws_eip" "ec2_eip" {
  count = var.enable_autoscaling ? 0 : (var.enable_eip ? var.instance_count : 0)

  domain = "vpc"
  tags = merge({
    Name          = "${local.kebab_instance_name}-eip-${var.environment}-${count.index}"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

# Associate Elastic IP to Linux Server
resource "aws_eip_association" "ec2_eip_association" {
  count = var.enable_autoscaling ? 0 : (var.enable_eip ? var.instance_count : 0)

  instance_id   = element(aws_instance.ec2_instance, count.index).id
  allocation_id = aws_eip.ec2_eip[count.index].id
}

### Elastic LB Start ###
########################

# Add Load Balancing if needed and enabled
resource "aws_lb" "ec2_lb" {
  count              = local.enable_load_balancer ? 1 : 0
  name               = "${local.kebab_instance_name}-lb"
  load_balancer_type = "application"

  subnets         = var.subnet_ids
  security_groups = [var.security_group_id]

  tags = merge({
    Name          = "${local.kebab_instance_name}-lb"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_lb_target_group" "ec2_lb_target_group" {
  count = local.enable_load_balancer ? 1 : 0
  name  = "${local.kebab_instance_name}-lb-tg"

  vpc_id   = data.aws_subnet.random_subnet.vpc_id
  protocol = "TCP"
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
    Name          = "${local.kebab_instance_name}-http-lb-tg"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_lb_target_group_attachment" "ec2_lb_target_group_attachment" {
  count = var.enable_autoscaling ? 1 : 0

  target_group_arn = aws_lb_target_group.ec2_lb_target_group[0].arn
  target_id        = aws_instance.ec2_instance[count.index].id
  port             = var.elb_instance_port
}

resource "aws_lb_listener" "ec2_lb_listener" {
  count = local.enable_load_balancer ? 1 : 0

  load_balancer_arn = aws_lb.ec2_lb[0].arn
  port              = aws_lb_target_group.ec2_lb_target_group[0].port
  protocol          = aws_lb_target_group.ec2_lb_target_group[0].protocol

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_lb_target_group[0].arn
  }
}

resource "aws_lb_target_group" "ec2_lb_https_target_group" {
  count = local.enable_https_load_balancer ? 1 : 0
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
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_lb_target_group_attachment" "ec2_lb_https_target_group_attachment" {
  count = var.enable_autoscaling ? 1 : 0
  target_group_arn = aws_lb_target_group.ec2_lb_https_target_group[0].arn
  target_id        = aws_instance.ec2_instance[count.index].id
  port             = aws_lb_target_group.ec2_lb_https_target_group[0].port
}

resource "aws_lb_listener" "ec2_lb_https_listener" {
  count = local.enable_https_load_balancer ? 1 : 0
  load_balancer_arn = aws_lb.ec2_lb[0].arn
  port              = aws_lb_target_group.ec2_lb_https_target_group[0].port
  protocol          = aws_lb_target_group.ec2_lb_https_target_group[0].protocol
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_lb_https_target_group[0].arn
  }
}

### Autoscaling Start ###
#########################

resource "aws_launch_template" "ec2_lt" {
  count = var.enable_autoscaling ? 1 : 0

  name_prefix   = "${local.kebab_instance_name}-lt-"
  image_id      = local.selected_ami
  instance_type = var.instance_type
  key_name      = var.key_pair_key_name

  vpc_security_group_ids = [var.security_group_id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  metadata_options {
    http_protocol_ipv6 = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.instance_ebs_primary_size
      encrypted             = false
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge({
      Name          = "${local.kebab_instance_name}-${var.environment}"
      Group         = var.resource_group
      InstanceGroup = local.snake_instance_name
      Environment   = var.environment
      Type          = "Self Made"
    }, var.tags)
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge({
      Name          = "${local.kebab_instance_name}-root-${var.environment}"
      InstanceGroup = local.snake_instance_name
      Group         = var.resource_group
      Environment   = var.environment
      Type          = "Self Made"
    }, var.tags)
  }

  user_data = base64encode(
    templatefile(
      "${path.module}/cloud_init_data.yaml.tftpl",
      {
        app_name    = local.snake_instance_name
        environment = var.environment
        app_port    = var.app_port
        volume_id   = ""  # Autoscaling instances handle volume attachment separately
      }
    )
  )

  lifecycle {
    create_before_destroy = true
  }

  tags = merge({
    Name          = "${local.kebab_instance_name}-launch-template"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_autoscaling_group" "ec2_asg" {
  count = var.enable_autoscaling ? 1 : 0

  name                = "${local.kebab_instance_name}-asg-${var.environment}"
  min_size            = var.autoscaling_min_size
  max_size            = var.autoscaling_max_size
  desired_capacity    = var.autoscaling_desired_capacity
  vpc_zone_identifier = var.subnet_ids
  health_check_type   = var.enable_elb ? "ELB" : "EC2"
  health_check_grace_period = 60
  default_cooldown    = var.autoscaling_scale_out_cooldown

  target_group_arns = var.enable_elb ? concat(
    [aws_lb_target_group.ec2_lb_target_group[0].arn],
    var.enable_elb_https ? [aws_lb_target_group.ec2_lb_https_target_group[0].arn] : []
  ) : []

  launch_template {
    id      = aws_launch_template.ec2_lt[0].id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.instance_name}-${var.environment}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Group"
    value               = var.resource_group
    propagate_at_launch = true
  }

  tag {
    key                 = "InstanceGroup"
    value               = local.snake_instance_name
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "Type"
    value               = "Self Made"
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 60
    }
    triggers = ["tag"]
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "cpu_target" {
  count = var.enable_autoscaling ? 1 : 0

  name                   = "${local.kebab_instance_name}-cpu-target-${var.environment}"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.ec2_asg[0].name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.autoscaling_cpu_target_percent
  }

  estimated_instance_warmup = 60
}

### IAM Role for EC2 Instances ###
####################################

resource "aws_iam_role" "ec2_instance_role" {
  name  = "${local.kebab_instance_name}-instance-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = merge({
    Name          = "${local.kebab_instance_name}-instance-role"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_iam_role_policy" "ec2_instance_policy" {
  name  = "${local.kebab_instance_name}-instance-policy-${var.environment}"
  role  = aws_iam_role.ec2_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::*-elixir-deploys-${var.environment}",
          "arn:aws:s3:::*-elixir-deploys-${var.environment}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "ec2:DescribeVolumes",
          "ec2:DescribeTags",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:CreateImage",
          "ec2:CreateTags",
          "ec2:DescribeImages",
          "ec2:DeregisterImage",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
          "logs:CreateLogStream",
          "logs:CreateLogGroup",
          "ssm:PutParameter"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/deploy_ex/${var.environment}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name  = "${local.kebab_instance_name}-instance-profile-${var.environment}"
  role  = aws_iam_role.ec2_instance_role.name

  tags = merge({
    Name          = "${local.kebab_instance_name}-instance-profile"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Type          = "Self Made"
  }, var.tags)
}
