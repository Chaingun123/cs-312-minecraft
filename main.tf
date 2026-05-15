terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  # If you configured a named profile above, add: profile = "cs312"
}

# Use the default VPC instead of creating a new one
data "aws_vpc" "default" {
  default = true
}

# Security Group for the control node: SSH access from your laptop
resource "aws_security_group" "control" {
  name        = "cs312-tf-control-sg"
  description = "Control node: SSH only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "cs312-tf-control-sg"
  }
}

#bucket logic
resource "aws_s3_bucket" "backups" {
  bucket = var.backup_name

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = var.backup_name
    Project = "cs312-minecraft"
    Purpose = "minecraft-backups"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

#security rules per assignment
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
# Security Group for the managed node: SSH from control node only, HTTP from anywhere
resource "aws_security_group" "managed" {
  name        = "cs312-tf-managed-sg"
  description = "Managed node: SSH from control node, HTTP from anywhere"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "SSH from control node"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.control.id]
  }

  ingress {
    description = "Minecraft"
    from_port   = 25565
    to_port     = 25565
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }



  tags = {
    Name = "cs312-tf-managed-sg"
  }
}

# Control node: you SSH into this instance from your laptop
resource "aws_instance" "control" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.control.id]
  iam_instance_profile   = "LabInstanceProfile"
  #user data to bootstrap the ansible install
  user_data = <<-EOF
  #cloud-config
  package_update: true
  package_upgrade: false
  packages:
    - ansible
    - git
    - awscli
    - python3-pip
  EOF

  tags = {
    Name = "cs312-minecraft-control"
  }
}

# Managed node: the server that will run the application
resource "aws_instance" "managed" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.managed.id]
  iam_instance_profile   = "LabInstanceProfile"



  root_block_device {
    volume_size           = 20
    delete_on_termination = true
  }


  tags = {
    Name = "cs312-minecraft-managed"
  }
}

# ECR repository for the CI/CD pipeline
resource "aws_ecr_repository" "minecraft" {
  name                 = "cs312-minecraft"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

#run ansible and add the inventory for ansible
resource "null_resource" "ansible_chain" {
  triggers = {
    control_id    = aws_instance.control.id
    managed_id    = aws_instance.managed.id
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_instance.control.public_ip
    private_key = file(pathexpand(var.keypath))
  }
  #wait for apt
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "ansible --version",
    ]
  }

  #upload the needed files so control node can run and connect
  provisioner "file" {
    source      = pathexpand(var.keypath)
    destination = "/home/ubuntu/.ssh/${var.key_name}.pem"
  }

  provisioner "file" {
    source      = "${path.module}/${var.ansible_dir}"
    destination = "/home/ubuntu"
  }


  #set up ansible variables
  provisioner "remote-exec" {
    inline = [
      "chmod 600 /home/ubuntu/.ssh/${var.key_name}.pem",
      "cat > /home/ubuntu/ansible/inventory.ini <<EOF\n[minecraft]\nmanaged ansible_host=${aws_instance.managed.private_ip} ansible_user=ubuntu\nEOF",
      <<-EOT
      cat > /home/ubuntu/ansible/vars.yml <<VARS
      ecr_registry: ${aws_ecr_repository.minecraft.repository_url}
      backup_bucket: ${aws_s3_bucket.backups.id}
      aws_region: us-east-1
      image_tag: ${var.image_tag}
      VARS
      EOT
    ,

      "cd /home/ubuntu/ansible && ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook  --private-key /home/ubuntu/.ssh/${var.key_name}.pem -i inventory.ini minecraft.yml",
    ]
  }

  depends_on = [
    aws_instance.control,
    aws_instance.managed,
    aws_s3_bucket.backups,
    aws_ecr_repository.minecraft,
  ]
}
