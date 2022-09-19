# Pulls debian image from AWS AMI
data "aws_ami" "debian-11" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-11*amd64*"]
  }
}

# Create EC2 Instance
resource "aws_instance" "ec2_instance" {
  # Enable when multi-instancing
  count = var.instance_count || 1

  ami           = data.aws_ami.debian-11.id
  instance_type = var.instance_type

  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]

  key_name = var.key_pair_key_name

  private_dns_name_options {
    hostname_type                     = "resource-name"
    enable_resource_name_dns_a_record = true
  }

  user_data = var.disable_ebs ? "" : file("${path.module}/user_data_init_script.sh")

  tags = {
    Name        = format("%s-%s", var.instance_name, count.index)
    Group       = var.resource_group
    Environment = var.environment
  }
}

### EBS Start ###
#################

# Create EBS Volume
resource "aws_ebs_volume" "ec2_ebs" {
  count             = var.disable_ebs ? 0 : 1

  availability_zone = "us-west-2a"
  size              = var.instance_ebs_secondary_size

  tags = {
    Name        = format("%s-%s-%s", var.instance_name, "ebs", count.index) # instance-name-ebs
    Group       = var.resource_group
    Environment = var.environment
  }
}

# Attach EBS Volume
resource "aws_volume_attachment" "ec2_ebs_association" {
  count       = var.disable_ebs ? 0 : 1

  for_each    = aws_instance.ec2_instance

  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ec2_ebs[count.index].id
  instance_id = each.value.id
}

### Elastic IP Start ###
########################

# Create Elastic IP
resource "aws_eip" "ec2_eip" {
  count = var.instance_count || 1

  vpc = true
  tags = {
    Name        = format("%s-%s-%s", var.instance_name, "eip", count.index) # instance-name-eip
    Group       = var.resource_group
    Environment = var.environment
  }
}

# Associate Elastic IP to Linux Server
resource "aws_eip_association" "ec2_eip_association" {
  count = var.instance_count || 1

  instance_id   = aws_instance.ec2_instance[count.index].id
  allocation_id = aws_eip.ec2_eip[count.index].id
}
