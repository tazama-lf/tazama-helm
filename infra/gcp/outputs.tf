# SPDX-License-Identifier: Apache-2.0

output "public_ip" {
  description = "Static external IP of the k3s node."
  value       = google_compute_address.k3s.address
}

output "ssh_user" {
  value = local.ssh_user
}

output "ssh_key_path" {
  description = "Private key written next to this stack (gitignored)."
  value       = abspath(local_sensitive_file.ssh_private_key.filename)
}

output "ssh_command" {
  value = "ssh -i ${abspath(local_sensitive_file.ssh_private_key.filename)} -o StrictHostKeyChecking=no ${local.ssh_user}@${google_compute_address.k3s.address}"
}

output "kubeconfig_remote" {
  description = "Path on the instance. up.ps1 copies this locally."
  value       = "/home/${local.ssh_user}/kubeconfig.yaml"
}

output "operator_cidr" {
  description = "CIDR allowed to SSH and :6443."
  value       = local.operator_cidr
}

output "sizing" {
  description = "Helm -Sizing value used for this cluster."
  value       = var.sizing
}

output "instance_type" {
  description = "GCE machine type selected from sizing."
  value       = local.machine_type
}

output "project" {
  value = var.project
}

output "next_sync" {
  description = "Install Tazama from this repo once KUBECONFIG is set."
  value       = ".\\tazama.cmd sync -Profile core -Cloud onprem -Sizing ${var.sizing}"
}
