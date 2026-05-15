variable "ami_id" {
  description = "AMI ID for the EC2 instance (Ubuntu 26.04 in us-east-1)"
  type        = string
  default     = "ami-091138d0f0d41ff90"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "Name of the SSH key pair (must already exist in AWS)"
  type        = string
  default     = "ArchPC"
}

variable "keypath" {
  type        = string
  default = "~/.ssh/ArchPC.pem"
}

variable "backup_name" {
  description = "S3 bucket for Minecraft world backups."
  type        = string
  default     = "mc-backups-1"
}

variable "ansible_dir" {
  type        = string
  default     = "ansible"
}

variable "image_tag" {
  type = string
  default = "mc-1.21.4-1"
}
