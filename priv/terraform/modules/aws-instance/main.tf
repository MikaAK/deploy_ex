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
  # count = var.instance_count

  ami           = data.aws_ami.debian-11.id
  instance_type = var.instance_type

  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]

  key_name = var.key_pair_key_name

  private_dns_name_options {
    hostname_type = "resource-name"
    enable_resource_name_dns_a_record = true
  }

  # user_data = templatefile("${path.module}/user_data_init_script.sh.tpl", {instance_name = var.instance_name})

  tags = {
    Name  = var.instance_name
    Group = var.instance_group
    Environment = var.environment
  }
}

# Create Elastic IP
resource "aws_eip" "ec2_eip" {
  vpc  = true
  tags = {
    Name  = format("%s-%s", var.instance_name, "eip") # instance-name-eip
    Group = var.instance_group
    Environment = var.environment
  }
}

# Associate Elastic IP to Linux Server
resource "aws_eip_association" "ec2_eip_association" {
  instance_id   = aws_instance.ec2_instance.id
  allocation_id = aws_eip.ec2_eip.id
}
