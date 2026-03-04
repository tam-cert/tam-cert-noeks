terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# ─── Variables ────────────────────────────────────────────────────────────────

variable "vpc_cidr"         { default = "172.49.0.0/16" }
variable "subnet_cidr"      { default = "172.49.20.0/24" }
variable "master_ip"        { default = "172.49.20.230" }
variable "node1_ip"         { default = "172.49.20.231" }
variable "node2_ip"         { default = "172.49.20.232" }
variable "training_prefix"  { default = "grant-tam" }
variable "customer_ip"      { default = "136.25.0.29/32" }
variable "key_pair_name"    { default = "grant-tam-key" }
variable "tf_state_bucket"  { description = "S3 bucket used for Terraform state and key storage" }
variable "github_repo"      { default = "https://raw.githubusercontent.com/<your-org>/tam-cert-noeks/main" }

# ─── SSH Key Pair ─────────────────────────────────────────────────────────────

resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "main" {
  key_name   = var.key_pair_name
  public_key = tls_private_key.main.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.main.private_key_pem
  filename        = "${path.module}/${var.key_pair_name}.pem"
  file_permission = "0600"
}

# ─── AMI Lookup ───────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ─── Networking ───────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags = { Name = "${var.training_prefix}-vpc1" }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  map_public_ip_on_launch = true
  tags = { Name = "${var.training_prefix}-subnet-1" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.training_prefix}-IGW" }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.training_prefix}-RT" }
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# ─── Security Group ───────────────────────────────────────────────────────────

resource "aws_security_group" "main" {
  name        = "${var.training_prefix}-SG"
  description = "${var.training_prefix} Security Group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from customer"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.customer_ip]
  }

  ingress {
    description = "All traffic within cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.training_prefix}-SG" }
}

# ─── cloud-init: Master ───────────────────────────────────────────────────────
# - Installs kubectl, kubeadm, kubelet, ansible
# - Pulls ansible playbooks from GitHub
# - Runs k8s-setup and k8s-master playbooks locally

locals {
  master_userdata = <<-EOT
    #!/bin/bash
    set -euo pipefail

    # Write SSH private key so Ansible can reach worker nodes
    mkdir -p /home/ubuntu/.ssh
    cat <<'PRIVATEKEY' > /home/ubuntu/.ssh/id_rsa
    ${tls_private_key.main.private_key_pem}
    PRIVATEKEY
    chmod 600 /home/ubuntu/.ssh/id_rsa
    chown ubuntu:ubuntu /home/ubuntu/.ssh/id_rsa

    # Kubernetes apt repo
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl ansible
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
      > /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubectl kubeadm kubelet
    apt-mark hold kubelet kubeadm kubectl

    # Pull ansible files from GitHub
    REPO="${var.github_repo}"
    ANSIBLE_DIR="/home/ubuntu/ansible"
    mkdir -p "$ANSIBLE_DIR"

    for f in ansible.cfg hosts k8s-setup.yaml k8s-master.yaml k8s-workers.yaml; do
      curl -fsSL "$REPO/ansible/$f" -o "$ANSIBLE_DIR/$f"
    done

    chown -R ubuntu:ubuntu "$ANSIBLE_DIR"
    cp "$ANSIBLE_DIR/ansible.cfg" /home/ubuntu/.ansible.cfg

    # Run playbooks
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/k8s-setup.yaml"   -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/k8s-master.yaml"  -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/k8s-workers.yaml" -i "$ANSIBLE_DIR/hosts" --become
  EOT

  # ─── cloud-init: Workers ─────────────────────────────────────────────────
  # - Installs kubeadm, kubelet
  # - Master will SSH in via Ansible to complete join

  worker_userdata = <<-EOT
    #!/bin/bash
    set -euo pipefail

    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl python3
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
      > /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubeadm kubelet
    apt-mark hold kubelet kubeadm
  EOT
}

# ─── EC2 Instances ────────────────────────────────────────────────────────────

locals {
  common_tags = {
    instance_metadata_tagging_req = "grant.voss@goteleport.com"
  }
}

resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.small"
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id
  source_dest_check      = false
  private_ip             = var.master_ip
  user_data              = local.master_userdata

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-master"
  })

  volume_tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-master-volume"
  })
}

resource "aws_instance" "node1" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.small"
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id
  source_dest_check      = false
  private_ip             = var.node1_ip
  user_data              = local.worker_userdata

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-node1"
  })

  volume_tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-node1-volume"
  })
}

resource "aws_instance" "node2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.small"
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id
  source_dest_check      = false
  private_ip             = var.node2_ip
  user_data              = local.worker_userdata

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-node2"
  })

  volume_tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-node2-volume"
  })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "master_public_ip"   { value = aws_instance.master.public_ip }
output "master_private_ip"  { value = aws_instance.master.private_ip }
output "node1_private_ip"   { value = aws_instance.node1.private_ip }
output "node2_private_ip"   { value = aws_instance.node2.private_ip }
output "private_key_s3_path" { value = "s3://${var.tf_state_bucket}/keys/${var.key_pair_name}.pem"
  sensitive = false
}
output "private_key_path"   { value = local_sensitive_file.private_key.filename }
output "ubuntu_ami_id"      { value = data.aws_ami.ubuntu.id }
output "ubuntu_ami_name"    { value = data.aws_ami.ubuntu.name }
