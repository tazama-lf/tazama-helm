# SPDX-License-Identifier: Apache-2.0

variable "prefix" {
  description = "Name prefix for AWS resources."
  type        = string
  default     = "tazama-k3s"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile. Empty uses the default chain (env vars, instance role, default profile)."
  type        = string
  default     = ""
}

variable "sizing" {
  description = "Helm replica tier. Also picks the EC2 type: small=t3.medium, medium=t3.large, large=t3.xlarge."
  type        = string
  default     = "medium"

  validation {
    condition     = contains(["small", "medium", "large"], var.sizing)
    error_message = "sizing must be small, medium, or large."
  }
}

variable "root_volume_gb" {
  description = "Root disk for k3s and local-path PVCs."
  type        = number
  default     = 80
}

variable "allowed_cidr" {
  description = "Who can reach SSH (22) and the Kubernetes API (6443). Empty = this machine's public IP /32."
  type        = string
  default     = ""
}
