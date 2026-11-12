# SPDX-License-Identifier: Apache-2.0
#
# One public GCE VM running k3s. Not GKE. Laptop Helmfile / Lens talk to :6443.
# Tear down with tofu destroy (or .\down.ps1).

data "http" "operator_ip" {
  url = "https://checkip.amazonaws.com/"
}

locals {
  ssh_user      = "ubuntu"
  operator_cidr = var.allowed_cidr != "" ? var.allowed_cidr : "${chomp(data.http.operator_ip.response_body)}/32"
  machine_type = {
    small  = "e2-medium"
    medium = "e2-standard-2"
    large  = "e2-standard-4"
  }[var.sizing]
  wait_k3s = replace(<<-EOT
set -eu
for i in $(seq 1 72); do
  if [ -f /home/${local.ssh_user}/READY ]; then
    exit 0
  fi
  if [ -f /var/log/syslog ]; then
    if grep -q 'startup-script.*Failed' /var/log/syslog 2>/dev/null; then
      echo 'startup-script failed; last log:'
      tail -n 80 /var/log/syslog || true
      exit 1
    fi
  fi
  sleep 10
done
echo 'k3s did not become ready in 12 minutes; last log:'
journalctl -u google-startup-scripts --no-pager -n 80 || tail -n 80 /var/log/syslog || true
exit 1
EOT
  , "\r", "")
}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "ssh_private_key" {
  filename        = "${path.module}/id_rsa"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

resource "google_compute_network" "this" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "public" {
  name          = "${var.prefix}-public"
  ip_cidr_range = "10.42.1.0/24"
  region        = var.region
  network       = google_compute_network.this.id
}

resource "google_compute_firewall" "k3s" {
  name    = "${var.prefix}-sg"
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }

  allow {
    protocol = "tcp"
    ports    = ["30000-32767"]
  }

  source_ranges = [local.operator_cidr]
  target_tags   = [var.prefix]
}

resource "google_compute_address" "k3s" {
  name   = "${var.prefix}-eip"
  region = var.region
}

resource "google_compute_instance" "k3s" {
  name         = "${var.prefix}-${var.sizing}"
  machine_type = local.machine_type
  zone         = var.zone
  tags         = [var.prefix]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.root_volume_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public.id
    access_config {
      nat_ip = google_compute_address.k3s.address
    }
  }

  metadata = {
    ssh-keys = "${local.ssh_user}:${tls_private_key.ssh.public_key_openssh}"
    startup-script = replace(templatefile("${path.module}/user_data.sh.tftpl", {
      eip      = google_compute_address.k3s.address
      ssh_user = local.ssh_user
    }), "\r", "")
  }

  allow_stopping_for_update = true

  labels = {
    tazama-sizing   = var.sizing
    tazama-instance = replace(local.machine_type, "/", "-")
  }

  connection {
    type        = "ssh"
    user        = local.ssh_user
    private_key = tls_private_key.ssh.private_key_pem
    host        = google_compute_address.k3s.address
    timeout     = "12m"
  }

  provisioner "remote-exec" {
    inline = [local.wait_k3s]
  }

  depends_on = [
    google_compute_firewall.k3s,
  ]
}

resource "terraform_data" "kubeconfig" {
  depends_on = [google_compute_instance.k3s]

  triggers_replace = [
    google_compute_instance.k3s.id,
    google_compute_address.k3s.address,
  ]

  connection {
    type        = "ssh"
    user        = local.ssh_user
    private_key = tls_private_key.ssh.private_key_pem
    host        = google_compute_address.k3s.address
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "test -f /home/${local.ssh_user}/kubeconfig.yaml",
    ]
  }
}
