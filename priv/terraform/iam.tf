### Shared IAM Role for All EC2 Instances ###
##############################################

resource "aws_iam_role" "ec2_instance_role" {
  name = "deploy-ex-ec2-instance-role-${var.environment}"

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

  tags = {
    Name        = "deploy-ex-ec2-instance-role"
    Environment = var.environment
    ManagedBy   = "DeployEx"
    Type        = "Shared"
  }
}

resource "aws_iam_role_policy" "ec2_instance_policy" {
  name = "deploy-ex-ec2-instance-policy-${var.environment}"
  role = aws_iam_role.ec2_instance_role.id

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
          "ec2:DeleteSnapshot",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
          "logs:CreateLogStream",
          "logs:CreateLogGroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/deploy_ex/${var.environment}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "deploy-ex-ec2-instance-profile-${var.environment}"
  role = aws_iam_role.ec2_instance_role.name

  tags = {
    Name        = "deploy-ex-ec2-instance-profile"
    Environment = var.environment
    ManagedBy   = "DeployEx"
    Type        = "Shared"
  }
}
