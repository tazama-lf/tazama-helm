# SPDX-License-Identifier: Apache-2.0

variable "prefix" {
  description = "Name prefix for GCP resources."
  type        = string
  default     = "tazama-k3s"
}

variable "project" {
  description = "GCP project ID (not the display name)."
  type        = string
}

variable "region" {
  description = "GCP region."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GCP zone in that region."
  type        = string
  default     = "europe-west1-b"
}

variable "sizing" {
  description = "Helm replica tier. Also picks the machine type: small=e2-medium, medium=e2-standard-2, large=e2-standard-4."
  type        = string
  default     = "medium"

  validation {
    condition     = contains(["small", "medium", "large"], var.sizing)
    error_message = "sizing must be small, medium, or large."
  }
}

variable "root_volume_gb" {
  description = "Boot disk for k3s and local-path PVCs."
  type        = number
  default     = 80
}

variable "allowed_cidr" {
  description = "Who can reach SSH (22) and the Kubernetes API (6443). Empty = this machine's public IP /32."
  type        = string
  default     = ""
}
