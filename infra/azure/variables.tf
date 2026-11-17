# SPDX-License-Identifier: Apache-2.0

variable "prefix" {
  description = "Name prefix for Azure resources."
  type        = string
  default     = "tazama-k3s"
}

variable "subscription_id" {
  description = "Azure subscription ID (GUID)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westeurope"
}

variable "sizing" {
  description = "Helm replica tier. Also picks the VM size: small=Standard_B2s, medium=Standard_D2s_v5, large=Standard_D4s_v5."
  type        = string
  default     = "medium"

  validation {
    condition     = contains(["small", "medium", "large"], var.sizing)
    error_message = "sizing must be small, medium, or large."
  }
}

variable "root_volume_gb" {
  description = "OS disk for k3s and local-path PVCs."
  type        = number
  default     = 80
}

variable "allowed_cidr" {
  description = "Who can reach SSH (22) and the Kubernetes API (6443). Empty = this machine's public IP /32."
  type        = string
  default     = ""
}
