# SPDX-License-Identifier: Apache-2.0

output "public_ip" {
  description = "Elastic IP of the k3s node."
  value       = aws_eip.k3s.public_ip
}

output "ssh_user" {
  value = "ec2-user"
}

output "ssh_key_path" {
  description = "Private key written next to this stack (gitignored)."
  value       = abspath(local_sensitive_file.ssh_private_key.filename)
}

output "ssh_command" {
  value = "ssh -i ${abspath(local_sensitive_file.ssh_private_key.filename)} -o StrictHostKeyChecking=no ec2-user@${aws_eip.k3s.public_ip}"
}

output "kubeconfig_remote" {
  description = "Path on the instance. up.ps1 copies this locally."
  value       = "/home/ec2-user/kubeconfig.yaml"
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
  description = "EC2 type selected from sizing."
  value       = local.instance_type
}

output "next_sync" {
  description = "Install Tazama from this repo once KUBECONFIG is set."
  value       = ".\\tazama.cmd sync -Profile core -Cloud onprem -Sizing ${var.sizing}"
}
