# SPDX-License-Identifier: Apache-2.0

output "public_ip" {
  description = "Static public IP of the k3s node."
  value       = azurerm_public_ip.k3s.ip_address
}

output "ssh_user" {
  value = local.ssh_user
}

output "ssh_key_path" {
  description = "Private key written next to this stack (gitignored)."
  value       = abspath(local_sensitive_file.ssh_private_key.filename)
}

output "ssh_command" {
  value = "ssh -i ${abspath(local_sensitive_file.ssh_private_key.filename)} -o StrictHostKeyChecking=no ${local.ssh_user}@${azurerm_public_ip.k3s.ip_address}"
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
  description = "Azure VM size selected from sizing."
  value       = local.vm_size
}

output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "next_sync" {
  description = "Install Tazama from this repo once KUBECONFIG is set."
  value       = ".\\tazama.cmd sync -Profile core -Cloud onprem -Sizing ${var.sizing}"
}
