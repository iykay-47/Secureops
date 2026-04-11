# AMI — latest Amazon Linux 2023 (overridable via var.ami_id)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id         = var.ami_id != null ? var.ami_id : data.aws_ami.al2023.id
  log_group_name = "/${var.project_name}/${var.environment}/pipeline"
  instance_id    = aws_instance.data_pipeline.id
}

# Use Default VPC
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Group — controls inbound and outbound traffic
resource "aws_security_group" "pipeline" {
  name        = "${var.project_name}-sg"
  description = "Secure pipeline instance. Allows SSH and all outbound."
  vpc_id      = data.aws_vpc.default.id

  # SSH access — scoped to var.ssh_cidr (ensure you IP is supplied as default is set to 0.0.0.0/0)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  # Allow all outbound — instance needs to reach S3, CloudWatch, SSM endpoints
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Module = "ec2-instance"
    Name   = "${var.project_name}-sg"
  })
}

# SSM — attach AWS managed policy to the pipeline role so Session Manager works
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_instance_profile.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

  depends_on = [aws_iam_role.ec2_instance_profile]
}

# EC2 Instance
resource "aws_instance" "data_pipeline" {
  ami                         = local.ami_id
  instance_type               = "t2.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name
  key_name                    = var.key_name != "" ? var.key_name : null
  vpc_security_group_ids      = [aws_security_group.pipeline.id]
  associate_public_ip_address = true

  # Render user-data script with environment-specific values at plan time
  user_data = base64encode(templatefile("${path.root}/user-data.tftpl", {
    s3_bucket   = aws_s3_bucket.test_store.id
    region      = var.region
    environment = var.environment
    log_group   = local.log_group_name
  }))

  tags = merge(var.tags, {
    Module = "ec2-instance"
    Name   = "${var.project_name}-instance"
  })

  # Ensure IAM profile and SSM policy are ready before instance launches
  depends_on = [aws_iam_role_policy_attachment.ssm_policy, aws_iam_role_policy_attachment.ec2_assume_role, aws_s3_bucket.test_store]
}