# SPDX-License-Identifier: Apache-2.0
#
# One public EC2 running k3s. Not EKS. Laptop Helmfile / Lens talk to :6443.
# Tear down with tofu destroy (or .\down.ps1).

data "http" "operator_ip" {
  url = "https://checkip.amazonaws.com/"
}

locals {
  operator_cidr = var.allowed_cidr != "" ? var.allowed_cidr : "${chomp(data.http.operator_ip.response_body)}/32"
  instance_type = {
    small  = "t3.medium"
    medium = "t3.large"
    large  = "t3.xlarge"
  }[var.sizing]
  # Windows checkouts store CRLF. Bash then treats `set -eu\r` as `set -` plus
  # an invalid option and remote-exec dies before it can wait for k3s.
  wait_k3s = replace(<<-EOT
set -eu
for i in $(seq 1 72); do
  if [ -f /home/ec2-user/READY ]; then
    exit 0
  fi
  if sudo cloud-init status 2>/dev/null | grep -q '^status: error'; then
    echo 'cloud-init failed; last log:'
    sudo tail -n 80 /var/log/cloud-init-output.log || true
    exit 1
  fi
  sleep 10
done
echo 'k3s did not become ready in 12 minutes; last log:'
sudo tail -n 80 /var/log/cloud-init-output.log || true
exit 1
EOT
  , "\r", "")
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh" {
  key_name   = "${var.prefix}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_private_key" {
  filename        = "${path.module}/id_rsa"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "${var.prefix}-public" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-public-rt" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "k3s" {
  name        = "${var.prefix}-sg"
  description = "SSH and k3s API from the operator IP"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  ingress {
    description = "Kubernetes API (kubectl / Lens)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  ingress {
    description = "NodePort range (on-prem ingress)"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-sg" }
}

resource "aws_eip" "k3s" {
  domain = "vpc"
  tags   = { Name = "${var.prefix}-eip" }
}

resource "aws_instance" "k3s" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = local.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  key_name                    = aws_key_pair.ssh.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = replace(templatefile("${path.module}/user_data.sh.tftpl", {
    eip = aws_eip.k3s.public_ip
  }), "\r", "")

  tags = {
    Name           = "${var.prefix}-${var.sizing}"
    TazamaSizing   = var.sizing
    TazamaInstance = local.instance_type
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.ssh.private_key_pem
    host        = self.public_ip
    timeout     = "12m"
  }

  provisioner "remote-exec" {
    inline = [local.wait_k3s]
  }

  depends_on = [
    aws_internet_gateway.this,
    aws_route_table_association.public,
  ]
}

resource "aws_eip_association" "k3s" {
  instance_id   = aws_instance.k3s.id
  allocation_id = aws_eip.k3s.id
}

resource "terraform_data" "kubeconfig" {
  depends_on = [
    aws_instance.k3s,
    aws_eip_association.k3s,
  ]

  triggers_replace = [
    aws_instance.k3s.id,
    aws_eip_association.k3s.id,
  ]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.ssh.private_key_pem
    host        = aws_eip.k3s.public_ip
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "test -f /home/ec2-user/kubeconfig.yaml",
    ]
  }
}
