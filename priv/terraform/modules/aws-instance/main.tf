### Data Sources ###
####################

data "aws_caller_identity" "current" {}

data "aws_ami_ids" "latest_app_ami" {
  count          = var.use_latest_ami ? 1 : 0
  owners         = ["self"]
  sort_ascending = false

  filter {
    name   = "name"
    values = ["${lower(replace(var.instance_name, " ", "_"))}-${var.environment}-*"]
  }
}

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


locals {
  latest_custom_ami = var.use_latest_ami && length(data.aws_ami_ids.latest_app_ami) > 0 && length(data.aws_ami_ids.latest_app_ami[0].ids) > 0 ? data.aws_ami_ids.latest_app_ami[0].ids[0] : null

  selected_ami   = coalesce(local.latest_custom_ami, var.instance_ami)
  use_latest_ami = local.latest_custom_ami != null && local.latest_custom_ami != var.instance_ami

  enable_load_balancer       = var.enable_elb && (var.instance_count > 1 || var.enable_autoscaling)
  enable_load_balancer_https = var.enable_elb && var.enable_elb_https

  snake_instance_name = lower(replace(var.instance_name, " ", "_"))
  kebab_instance_name = lower(replace(var.instance_name, " ", "-"))
  selected_subnet_id = var.instance_availability_zone != null ? (
    length(data.aws_subnets.az_specific[0].ids) > 0 ?
    data.aws_subnets.az_specific[0].ids[0] :
    random_shuffle.subnet_id.result[0]
  ) : random_shuffle.subnet_id.result[0]

  use_autoscaling_templates = var.enable_autoscaling && var.autoscaling_templates != null

  autoscaling_template_keys        = local.use_autoscaling_templates ? sort(keys(var.autoscaling_templates)) : []
  default_autoscaling_template_key = local.use_autoscaling_templates ? local.autoscaling_template_keys[0] : null

  autoscaling_pool_max_size = local.use_autoscaling_templates ? max([
    for template in values(var.autoscaling_templates) : coalesce(try(template.max_size, null), var.autoscaling_max_size)
  ]...) : var.autoscaling_max_size

  autoscaling_template_schedules = local.use_autoscaling_templates ? merge([
    for template_key, template in var.autoscaling_templates : {
      for schedule in coalesce(try(template.scheduling, null), []) : "${template_key}:${schedule.name}" => {
        template_key = template_key
        schedule     = schedule
      }
    }
  ]...) : {}

  autoscaling_template_enable_schedules = local.use_autoscaling_templates ? {
    for schedule_key, schedule_entry in local.autoscaling_template_schedules : schedule_key => schedule_entry
    if(
      coalesce(
        try(schedule_entry.schedule.changes.min_size, null),
        try(var.autoscaling_templates[schedule_entry.template_key].min_size, null),
        var.autoscaling_min_size
      ) > 0
      ||
      coalesce(
        try(schedule_entry.schedule.changes.max_size, null),
        try(var.autoscaling_templates[schedule_entry.template_key].max_size, null),
        var.autoscaling_max_size
      ) > 0
      ||
      coalesce(
        try(schedule_entry.schedule.changes.desired_capacity, null),
        try(var.autoscaling_templates[schedule_entry.template_key].desired_capacity, null),
        var.autoscaling_desired_capacity
      ) > 0
    )
  } : {}

  autoscaling_template_enable_schedules_disable_other_recurrence = {
    for schedule_key, schedule_entry in local.autoscaling_template_enable_schedules : schedule_key => (
      var.autoscaling_switch_disable_delay_minutes > 0
      && length(split(" ", schedule_entry.schedule.recurrence)) == 5
      && can(tonumber(element(split(" ", schedule_entry.schedule.recurrence), 0)))
      && can(tonumber(element(split(" ", schedule_entry.schedule.recurrence), 1)))
      ) ? join(" ", concat(
        [
          tostring((tonumber(element(split(" ", schedule_entry.schedule.recurrence), 0)) + var.autoscaling_switch_disable_delay_minutes) % 60),
          tostring((tonumber(element(split(" ", schedule_entry.schedule.recurrence), 1)) + (
            (tonumber(element(split(" ", schedule_entry.schedule.recurrence), 0)) + var.autoscaling_switch_disable_delay_minutes) - ((tonumber(element(split(" ", schedule_entry.schedule.recurrence), 0)) + var.autoscaling_switch_disable_delay_minutes) % 60)
          ) / 60) % 24)
        ],
        slice(split(" ", schedule_entry.schedule.recurrence), 2, 5)
    )) : schedule_entry.schedule.recurrence
  }
}

# Create EC2 Instance
resource "aws_instance" "ec2_instance" {
  # Enable when multi-instancing, disable when autoscaling
  count = var.enable_autoscaling ? 0 : var.instance_count

  ami           = local.selected_ami
  instance_type = var.instance_type

  key_name             = var.key_pair_key_name
  iam_instance_profile = var.iam_instance_profile_name

  availability_zone      = coalesce(var.instance_availability_zone, data.aws_subnet.selected_subnet.availability_zone)
  subnet_id              = local.selected_subnet_id
  vpc_security_group_ids = [var.security_group_id]
  private_ip             = var.private_ip

  # Enable both IPv6 and IPv4 (dual-stack)
  ipv6_address_count          = var.disable_ipv6 ? 0 : 1
  associate_public_ip_address = !var.disable_public_ip

  metadata_options {
    http_protocol_ipv6 = "enabled"
  }

  private_dns_name_options {
    hostname_type                        = "resource-name"
    enable_resource_name_dns_a_record    = true
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

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/cloud_init_data.yaml.tftpl", {
    app_name          = local.snake_instance_name
    environment       = var.environment
    app_port          = var.app_port
    bucket_name       = var.release_bucket_name
    volume_id         = var.enable_ebs ? aws_ebs_volume.ec2_ebs[count.index].id : ""
    eip_allocation_id = ""
    github_token      = var.github_token
    github_repo       = var.github_repo
  })

  tags = merge({
    Name          = "${var.instance_name}-${var.environment}-${count.index}"
    Group         = var.resource_group
    InstanceGroup = local.snake_instance_name
    Environment   = var.environment
    Type          = "Self Made"
    ManagedBy     = "DeployEx"
    SetupComplete = local.use_latest_ami ? "true" : "false"
  }, var.tags)
}

### EBS Start ###
#################

# Create EBS Volume
# For autoscaling: creates a pool of volumes equal to max_size
# For static instances: creates volumes equal to instance_count
resource "aws_ebs_volume" "ec2_ebs" {
  count = var.enable_ebs ? (var.enable_autoscaling ? local.autoscaling_pool_max_size : var.instance_count) : 0

  availability_zone = coalesce(var.instance_availability_zone, data.aws_subnet.selected_subnet.availability_zone)
  size              = var.instance_ebs_secondary_size
  snapshot_id       = var.instance_ebs_secondary_snapshot_id
  type              = "gp3"

  tags = merge({
    Name            = "${local.kebab_instance_name}-ebs-${var.environment}-${count.index}"
    InstanceGroup   = local.snake_instance_name
    Group           = var.resource_group
    Environment     = var.environment
    Vendor          = "Self"
    Type            = "Self Made"
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

resource "aws_eip_association" "ec2_eip_association" {
  count = var.enable_autoscaling ? 0 : (var.enable_eip ? var.instance_count : 0)

  instance_id   = aws_instance.ec2_instance[count.index].id
  allocation_id = aws_eip.ec2_eip[count.index].id
}

resource "aws_eip" "asg_preserved_eip" {
  count = var.enable_autoscaling && var.preserve_eip_for_single_instance_asg ? 1 : 0

  domain = "vpc"
  tags = merge({
    Name          = "${local.kebab_instance_name}-asg-eip-${var.environment}"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
    ManagedBy     = "DeployEx"
  }, var.tags)
}

### Elastic LB Start ###
########################

# Add Load Balancing if needed and enabled
resource "aws_lb" "ec2_lb" {
  count              = local.enable_load_balancer ? 1 : 0
  name               = "${local.kebab_instance_name}-lb-${var.environment}"
  load_balancer_type = "network"

  subnets = var.subnet_ids

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
  name  = "${local.kebab_instance_name}-lb-tg-${var.environment}"

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
    Name          = "${local.kebab_instance_name}-lb-tg-${var.environment}"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_lb_target_group_attachment" "ec2_lb_target_group_attachment" {
  count = local.enable_load_balancer && !var.enable_autoscaling ? var.instance_count : 0

  target_group_arn = aws_lb_target_group.ec2_lb_target_group[0].arn
  target_id        = aws_instance.ec2_instance[count.index].id
  port             = var.elb_instance_port
}

resource "aws_lb_listener" "ec2_lb_listener" {
  count = local.enable_load_balancer ? 1 : 0

  load_balancer_arn = aws_lb.ec2_lb[0].arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_lb_target_group[0].arn
  }
}

resource "aws_lb_target_group" "ec2_lb_https_target_group" {
  count    = local.enable_load_balancer ? 1 : 0
  name     = "${local.kebab_instance_name}-lb-https-tg-${var.environment}"
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
  count            = local.enable_load_balancer && !var.enable_autoscaling ? var.instance_count : 0
  target_group_arn = aws_lb_target_group.ec2_lb_https_target_group[0].arn
  target_id        = aws_instance.ec2_instance[count.index].id
  port             = aws_lb_target_group.ec2_lb_https_target_group[0].port
}

resource "aws_lb_listener" "ec2_lb_https_listener" {
  count             = local.enable_load_balancer ? 1 : 0
  load_balancer_arn = aws_lb.ec2_lb[0].arn
  port              = 443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_lb_https_target_group[0].arn
  }
}

### Autoscaling Start ###
#########################
data "aws_instances" "autoscaling_instances" {
  filter {
    name   = "tag:InstanceGroup"
    values = ["${local.snake_instance_name}_${var.environment}"]
  }

  filter {
    name   = "instance-state-name"
    values = ["pending", "running"]
  }
}

resource "aws_launch_template" "ec2_lt" {
  count = var.enable_autoscaling && !local.use_autoscaling_templates ? 1 : 0

  name_prefix   = "${local.kebab_instance_name}-lt-${var.environment}-"
  image_id      = local.selected_ami
  instance_type = var.instance_type
  key_name      = var.key_pair_key_name
  description   = "Launch template for ${local.kebab_instance_name} using AMI: ${local.selected_ami}"

  vpc_security_group_ids = [var.security_group_id]

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  metadata_options {
    http_protocol_ipv6 = "enabled"
  }

  private_dns_name_options {
    hostname_type                        = "resource-name"
    enable_resource_name_dns_a_record    = true
    enable_resource_name_dns_aaaa_record = !var.disable_ipv6
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
      ManagedBy     = "DeployEx"
      SetupComplete = local.use_latest_ami ? "true" : "false"
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
        app_name          = local.snake_instance_name
        environment       = var.environment
        app_port          = var.app_port
        bucket_name       = var.release_bucket_name
        volume_id         = "" # Autoscaling instances handle volume attachment separately
        eip_allocation_id = var.preserve_eip_for_single_instance_asg ? aws_eip.asg_preserved_eip[0].id : ""
        github_token      = var.github_token
        github_repo       = var.github_repo
      }
    )
  )

  lifecycle {
    create_before_destroy = true
  }

  # Ensure ASG picks up new version automatically
  update_default_version = true

  tags = merge({
    Name          = "${local.kebab_instance_name}-launch-template"
    InstanceGroup = local.snake_instance_name
    Group         = var.resource_group
    Environment   = var.environment
    Type          = "Self Made"
  }, var.tags)
}

resource "aws_autoscaling_group" "ec2_asg" {
  count = var.enable_autoscaling && !local.use_autoscaling_templates ? 1 : 0

  name                      = "${local.kebab_instance_name}-asg-${var.environment}"
  min_size                  = var.autoscaling_min_size
  max_size                  = var.autoscaling_max_size
  desired_capacity          = var.autoscaling_desired_capacity
  vpc_zone_identifier       = var.instance_availability_zone != null ? [local.selected_subnet_id] : var.subnet_ids
  health_check_type         = local.enable_load_balancer ? "ELB" : "EC2"
  health_check_grace_period = 60
  default_cooldown          = var.autoscaling_scale_out_cooldown

  target_group_arns = local.enable_load_balancer ? concat(
    [aws_lb_target_group.ec2_lb_target_group[0].arn],
    var.enable_elb_https ? [aws_lb_target_group.ec2_lb_https_target_group[0].arn] : []
  ) : []

  launch_template {
    id      = aws_launch_template.ec2_lt[0].id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 300
    }
    triggers = ["tag"]
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

  lifecycle {
    ignore_changes = [desired_capacity, min_size, max_size]
  }
}

resource "aws_launch_template" "ec2_lt_templates" {
  for_each = local.use_autoscaling_templates ? var.autoscaling_templates : {}

  name_prefix   = "${local.kebab_instance_name}-lt-${each.key}-${var.environment}"
  image_id      = coalesce(try(each.value.instance_ami, null), local.selected_ami)
  instance_type = each.value.instance_type
  key_name      = var.key_pair_key_name
  description   = "Launch template for ${local.kebab_instance_name} (${each.key}) using AMI: ${coalesce(try(each.value.instance_ami, null), local.selected_ami)}"

  vpc_security_group_ids = [var.security_group_id]

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  private_dns_name_options {
    hostname_type                        = "resource-name"
    enable_resource_name_dns_a_record    = true
    enable_resource_name_dns_aaaa_record = !var.disable_ipv6
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
      Name          = local.kebab_instance_name
      Group         = var.resource_group
      InstanceGroup = local.snake_instance_name
      Environment   = var.environment
      Type          = "Self Made"
      ManagedBy     = "DeployEx"
      SetupComplete = local.use_latest_ami ? "true" : "false"
    }, var.tags)
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge({
      Name          = "${local.kebab_instance_name}-root"
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
        app_name          = local.snake_instance_name
        environment       = var.environment
        app_port          = var.app_port
        bucket_name       = var.release_bucket_name
        volume_id         = ""
        eip_allocation_id = var.preserve_eip_for_single_instance_asg ? aws_eip.asg_preserved_eip[0].id : ""
        github_token      = var.github_token
        github_repo       = var.github_repo
      }
    )
  )

  lifecycle {
    create_before_destroy = true
  }

  update_default_version = true

  tags = merge({
    Name                   = "${local.kebab_instance_name}-launch-template-${each.key}"
    InstanceGroup          = "${local.snake_instance_name}_${var.environment}"
    Group                  = var.resource_group
    Environment            = var.environment
    Type                   = "Self Made"
    AutoscalingTemplateKey = each.key
  }, var.tags)
}

resource "aws_autoscaling_group" "ec2_asg_templates" {
  for_each = local.use_autoscaling_templates ? var.autoscaling_templates : {}

  name                      = "${local.kebab_instance_name}-asg-${each.key}-${var.environment}"
  min_size                  = coalesce(try(each.value.min_size, null), var.autoscaling_min_size)
  max_size                  = coalesce(try(each.value.max_size, null), var.autoscaling_max_size)
  desired_capacity          = coalesce(try(each.value.desired_capacity, null), var.autoscaling_desired_capacity)
  vpc_zone_identifier       = var.instance_availability_zone != null ? [local.selected_subnet_id] : var.subnet_ids
  health_check_type         = local.enable_load_balancer ? "ELB" : "EC2"
  health_check_grace_period = 60
  default_cooldown          = var.autoscaling_scale_out_cooldown

  target_group_arns = local.enable_load_balancer ? concat(
    [aws_lb_target_group.ec2_lb_target_group[0].arn],
    var.enable_elb_https ? [aws_lb_target_group.ec2_lb_https_target_group[0].arn] : []
  ) : []

  launch_template {
    id      = aws_launch_template.ec2_lt_templates[each.key].id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 300
    }
    triggers = ["tag"]
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
    value               = "${local.snake_instance_name}_${var.environment}"
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

  tag {
    key                 = "AutoscalingTemplateKey"
    value               = each.key
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity, min_size, max_size]
  }
}

resource "aws_autoscaling_policy" "cpu_target" {
  count = var.enable_autoscaling && !local.use_autoscaling_templates ? 1 : 0

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

resource "aws_autoscaling_policy" "cpu_target_templates" {
  for_each = local.use_autoscaling_templates ? var.autoscaling_templates : {}

  name                   = "${local.kebab_instance_name}-cpu-target-${each.key}-${var.environment}"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.ec2_asg_templates[each.key].name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.autoscaling_cpu_target_percent
  }

  estimated_instance_warmup = 60
}

resource "aws_autoscaling_schedule" "template_switch" {
  for_each = local.autoscaling_template_schedules

  scheduled_action_name  = "${local.kebab_instance_name}-${each.value.template_key}-${each.value.schedule.name}-${substr(sha1(each.value.schedule.recurrence), 0, 8)}-${var.environment}"
  autoscaling_group_name = aws_autoscaling_group.ec2_asg_templates[each.value.template_key].name
  recurrence             = each.value.schedule.recurrence
  time_zone              = try(each.value.schedule.time_zone, null)

  lifecycle {
    create_before_destroy = true
  }

  min_size = coalesce(
    try(each.value.schedule.changes.min_size, null),
    try(var.autoscaling_templates[each.value.template_key].min_size, null),
    var.autoscaling_min_size
  )

  max_size = coalesce(
    try(each.value.schedule.changes.max_size, null),
    try(var.autoscaling_templates[each.value.template_key].max_size, null),
    var.autoscaling_max_size
  )

  desired_capacity = coalesce(
    try(each.value.schedule.changes.desired_capacity, null),
    try(var.autoscaling_templates[each.value.template_key].desired_capacity, null),
    var.autoscaling_desired_capacity
  )
}

resource "aws_autoscaling_schedule" "template_switch_disable_others" {
  for_each = local.use_autoscaling_templates ? merge([
    for schedule_key, schedule_entry in local.autoscaling_template_enable_schedules : {
      for other_template_key in local.autoscaling_template_keys : "${schedule_key}:${other_template_key}" => {
        schedule_key       = schedule_key
        schedule_entry     = schedule_entry
        other_template_key = other_template_key
      } if other_template_key != schedule_entry.template_key
    }
  ]...) : {}

  scheduled_action_name  = "${local.kebab_instance_name}-${each.value.other_template_key}-off-${each.value.schedule_entry.schedule.name}-${substr(sha1(local.autoscaling_template_enable_schedules_disable_other_recurrence[each.value.schedule_key]), 0, 8)}-${var.environment}"
  autoscaling_group_name = aws_autoscaling_group.ec2_asg_templates[each.value.other_template_key].name
  recurrence             = local.autoscaling_template_enable_schedules_disable_other_recurrence[each.value.schedule_key]
  time_zone              = try(each.value.schedule_entry.schedule.time_zone, null)

  lifecycle {
    create_before_destroy = true
  }

  min_size         = 0
  max_size         = 0
  desired_capacity = 0
}
