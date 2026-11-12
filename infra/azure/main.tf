# SPDX-License-Identifier: Apache-2.0
#
# One public Azure VM running k3s. Not AKS. Laptop Helmfile / Lens talk to :6443.
# Tear down with tofu destroy (or .\down.ps1).

data "http" "operator_ip" {
  url = "https://checkip.amazonaws.com/"
}

locals {
  ssh_user      = "azureuser"
  operator_cidr = var.allowed_cidr != "" ? var.allowed_cidr : "${chomp(data.http.operator_ip.response_body)}/32"
  vm_size = {
    small  = "Standard_B2s"
    medium = "Standard_D2s_v5"
    large  = "Standard_D4s_v5"
  }[var.sizing]
  wait_k3s = replace(<<-EOT
set -eu
for i in $(seq 1 72); do
  if [ -f /home/${local.ssh_user}/READY ]; then
    exit 0
  fi
  sleep 10
done
echo 'k3s did not become ready in 12 minutes; last log:'
journalctl -u cloud-final --no-pager -n 80 || tail -n 80 /var/log/cloud-init-output.log || true
exit 1
EOT
  , "\r", "")
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

resource "azurerm_resource_group" "this" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags = {
    TazamaSizing = var.sizing
  }
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.42.0.0/16"]
}

resource "azurerm_subnet" "public" {
  name                 = "${var.prefix}-public"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.42.1.0/24"]
}

resource "azurerm_network_security_group" "k3s" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "kube-api"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "nodeports"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "30000-32767"
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.k3s.id
}

resource "azurerm_public_ip" "k3s" {
  name                = "${var.prefix}-eip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "k3s" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.k3s.id
  }
}

resource "azurerm_linux_virtual_machine" "k3s" {
  name                = "${var.prefix}-${var.sizing}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = local.vm_size
  admin_username      = local.ssh_user
  network_interface_ids = [
    azurerm_network_interface.k3s.id,
  ]

  disable_password_authentication = true

  admin_ssh_key {
    username   = local.ssh_user
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.root_volume_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(replace(templatefile("${path.module}/user_data.sh.tftpl", {
    eip      = azurerm_public_ip.k3s.ip_address
    ssh_user = local.ssh_user
  }), "\r", ""))

  tags = {
    TazamaSizing   = var.sizing
    TazamaInstance = local.vm_size
  }

  connection {
    type        = "ssh"
    user        = local.ssh_user
    private_key = tls_private_key.ssh.private_key_pem
    host        = azurerm_public_ip.k3s.ip_address
    timeout     = "12m"
  }

  provisioner "remote-exec" {
    inline = [local.wait_k3s]
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.public,
  ]
}

resource "terraform_data" "kubeconfig" {
  depends_on = [azurerm_linux_virtual_machine.k3s]

  triggers_replace = [
    azurerm_linux_virtual_machine.k3s.id,
    azurerm_public_ip.k3s.ip_address,
  ]

  connection {
    type        = "ssh"
    user        = local.ssh_user
    private_key = tls_private_key.ssh.private_key_pem
    host        = azurerm_public_ip.k3s.ip_address
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "test -f /home/${local.ssh_user}/kubeconfig.yaml",
    ]
  }
}
