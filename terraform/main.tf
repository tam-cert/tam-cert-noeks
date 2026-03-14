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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# ─── Variables ────────────────────────────────────────────────────────────────

variable "vpc_cidr"        { default = "172.49.0.0/16" }
variable "subnet_cidr"     { default = "172.49.20.0/24" }
variable "master_ip"       { default = "172.49.20.230" }
variable "node1_ip"        { default = "172.49.20.231" }
variable "node2_ip"        { default = "172.49.20.232" }
variable "training_prefix" { default = "grant-tam" }
variable "customer_ip"     { default = "136.25.0.29/32" }
variable "instance_type"   { default = "t3.medium" }
variable "key_pair_name"   { default = "grant-tam-key" }
variable "tf_state_bucket" { description = "S3 bucket used for Terraform state" }
variable "db_password" {
  description = "Master password for RDS PostgreSQL instance (used only for initial DB setup, not by Teleport)"
  sensitive   = true
}
variable "teleport_license" {
  description = "Teleport Enterprise license file contents"
  sensitive   = true
}
variable "teleport_node_port"              { default = "32443" }
variable "teleport_health_check_node_port" { default = "32444" }
variable "github_repo"     { default = "https://raw.githubusercontent.com/grantvoss-teleport/tam-cert-noeks/main" }
variable "aws_oidc_role_arn" {
  description = "ARN of the existing IAM role for Teleport AWS OIDC integration"
}
variable "okta_metadata_url" {
  description = "SAML metadata URL from Okta app Sign On tab"
}
variable "okta_groups_editor" {
  description = "Okta group name mapped to Teleport editor role"
}
variable "okta_groups_access" {
  description = "Okta group name mapped to Teleport access role"
}

# ─── IAM Role for EC2 instances ──────────────────────────────────────────────

resource "aws_iam_role" "ec2" {
  name = "${var.training_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

# Secrets Manager access — license only (DB password no longer needed by Teleport)
resource "aws_iam_role_policy" "secrets_manager" {
  name = "${var.training_prefix}-secrets-manager-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.teleport_license.arn
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.training_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

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
  owners      = ["099720109477"]

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
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.training_prefix}-vpc1" }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = "us-west-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.training_prefix}-subnet-1" }
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
    cidr_blocks = [var.customer_ip, "4.79.223.218/32"]
  }

  ingress {
    description = "HTTPS to Teleport"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Teleport NodePort"
    from_port   = 32443
    to_port     = 32443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NLB health check via healthCheckNodePort"
    from_port   = 32444
    to_port     = 32444
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    instance_metadata_tagging_req = "grant.voss@goteleport.com"
  }

  master_userdata = <<-EOT
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/cloud-init-k8s.log) 2>&1

    export DEBIAN_FRONTEND=noninteractive

    # ── Wait for apt lock ────────────────────────────────────────────────────
    systemctl disable --now unattended-upgrades || true
    systemctl disable --now apt-daily.timer || true
    systemctl disable --now apt-daily-upgrade.timer || true
    systemctl kill --kill-who=all apt-daily.service || true
    systemctl kill --kill-who=all apt-daily-upgrade.service || true

    systemd-run --property="After=apt-daily.service apt-daily-upgrade.service" \
      --wait /bin/true 2>/dev/null || true

    while fuser /var/lib/dpkg/lock-frontend \
                /var/lib/apt/lists/lock \
                /var/lib/dpkg/lock \
                /var/cache/apt/archives/lock >/dev/null 2>&1; do
      echo "Waiting for apt lock..."
      sleep 5
    done

    dpkg --configure -a || true
    sleep 5

    # ── Kernel modules & sysctl ──────────────────────────────────────────────
    modprobe overlay
    modprobe br_netfilter

    cat <<EOF > /etc/modules-load.d/k8s.conf
    overlay
    br_netfilter
    EOF

    cat <<EOF > /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
    EOF
    sysctl --system

    # ── Minimal dependencies ─────────────────────────────────────────────────
    apt_install() {
      for i in 1 2 3 4 5; do
        apt-get "$@" && return 0
        echo "apt-get failed (attempt $i), retrying in 15s..."
        sleep 15
      done
      return 1
    }

    apt_install update
    apt_install install -y apt-transport-https ca-certificates curl gnupg ansible python3 unzip

    # Install AWS CLI v2
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws

    # ── Write environment vars file ──────────────────────────────────────────
    cat <<EOF > /home/ubuntu/.teleport-env
    export RDS_ADDRESS="${aws_db_instance.teleport.address}"
    export SESSIONS_BUCKET="${aws_s3_bucket.teleport_sessions.bucket}"
    export LICENSE_SECRET_NAME="${aws_secretsmanager_secret.teleport_license.name}"
    export TELEPORT_OIDC_ROLE_ARN="${var.aws_oidc_role_arn}"
    export OKTA_METADATA_URL="${var.okta_metadata_url}"
    export OKTA_GROUPS_EDITOR="${var.okta_groups_editor}"
    export OKTA_GROUPS_ACCESS="${var.okta_groups_access}"
    export GITHUB_REPOSITORY="grantvoss-teleport/tam-cert-noeks"
    EOF
    chmod 600 /home/ubuntu/.teleport-env
    chown ubuntu:ubuntu /home/ubuntu/.teleport-env
    echo "source ~/.teleport-env" >> /home/ubuntu/.bashrc

    # ── SSH private key for Ansible ──────────────────────────────────────────
    mkdir -p /home/ubuntu/.ssh
    cat <<'PRIVATEKEY' > /home/ubuntu/.ssh/id_rsa
    ${tls_private_key.main.private_key_pem}
    PRIVATEKEY
    chmod 600 /home/ubuntu/.ssh/id_rsa
    chown ubuntu:ubuntu /home/ubuntu/.ssh/id_rsa

    # ── Pull Ansible roles from GitHub ───────────────────────────────────────
    REPO="${var.github_repo}"
    ANSIBLE_DIR="/home/ubuntu/ansible"

    mkdir -p "$ANSIBLE_DIR/roles/k8s-setup/tasks"
    mkdir -p "$ANSIBLE_DIR/roles/k8s-setup/defaults"
    mkdir -p "$ANSIBLE_DIR/roles/k8s-master/tasks"
    mkdir -p "$ANSIBLE_DIR/roles/k8s-workers/tasks"
    mkdir -p "$ANSIBLE_DIR/roles/teleport/tasks"
    mkdir -p "$ANSIBLE_DIR/roles/teleport/templates"
    mkdir -p "$ANSIBLE_DIR/roles/teleport-oidc/tasks"
    mkdir -p "$ANSIBLE_DIR/roles/teleport-sso/tasks"
    mkdir -p "$ANSIBLE_DIR/roles/teleport-rbac/tasks"
    mkdir -p "$ANSIBLE_DIR/roles/teleport-rbac/templates"
    mkdir -p "$ANSIBLE_DIR/roles/teleport-node/tasks"

    until curl -fsSL --max-time 5 https://raw.githubusercontent.com > /dev/null 2>&1; do
      echo "Waiting for GitHub to be reachable..."
      sleep 5
    done

    for f in ansible.cfg hosts site.yaml k8s-setup.yaml k8s-master.yaml k8s-workers.yaml teleport.yaml teleport-oidc.yaml teleport-sso.yaml teleport-rbac.yaml teleport-node.yaml; do
      echo "Fetching ansible/$f..."
      rm -f "$ANSIBLE_DIR/$f"
      curl -fsSL "$REPO/ansible/$f" -o "$ANSIBLE_DIR/$f" || { echo "ERROR: failed to fetch $f"; exit 1; }
    done

    for role_file in \
      "roles/k8s-setup/tasks/main.yaml" \
      "roles/k8s-setup/defaults/main.yaml" \
      "roles/k8s-master/tasks/main.yaml" \
      "roles/k8s-workers/tasks/main.yaml" \
      "roles/teleport/tasks/main.yaml" \
      "roles/teleport/templates/teleport-values.yaml.j2" \
      "roles/teleport-oidc/tasks/main.yaml" \
      "roles/teleport-sso/tasks/main.yaml" \
      "roles/teleport-rbac/tasks/main.yaml" \
      "roles/teleport-rbac/templates/machine-id-bot.yaml.j2" \
      "roles/teleport-rbac/templates/role-rbac-manager.yaml.j2" \
      "roles/teleport-node/tasks/main.yaml"; do
      echo "Fetching ansible/$role_file..."
      rm -f "$ANSIBLE_DIR/$role_file"
      curl -fsSL "$REPO/ansible/$role_file" -o "$ANSIBLE_DIR/$role_file" || { echo "ERROR: failed to fetch $role_file"; exit 1; }
    done

    chown -R ubuntu:ubuntu "$ANSIBLE_DIR"
    cp "$ANSIBLE_DIR/ansible.cfg" /home/ubuntu/.ansible.cfg

    # ── Run Ansible playbooks ────────────────────────────────────────────────
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/k8s-setup.yaml"     -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/k8s-master.yaml"    -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/k8s-workers.yaml"   -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/teleport.yaml"      -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/teleport-oidc.yaml" -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/teleport-sso.yaml"  -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/teleport-rbac.yaml" -i "$ANSIBLE_DIR/hosts" --become
    sudo -u ubuntu ansible-playbook "$ANSIBLE_DIR/teleport-node.yaml" -i "$ANSIBLE_DIR/hosts" --become
  EOT

  worker_userdata = <<-EOT
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/cloud-init-k8s.log) 2>&1

    export DEBIAN_FRONTEND=noninteractive

    systemctl disable --now unattended-upgrades || true
    systemctl disable --now apt-daily.timer || true
    systemctl disable --now apt-daily-upgrade.timer || true
    systemctl kill --kill-who=all apt-daily.service || true
    systemctl kill --kill-who=all apt-daily-upgrade.service || true

    systemd-run --property="After=apt-daily.service apt-daily-upgrade.service" \
      --wait /bin/true 2>/dev/null || true

    while fuser /var/lib/dpkg/lock-frontend \
                /var/lib/apt/lists/lock \
                /var/lib/dpkg/lock \
                /var/cache/apt/archives/lock >/dev/null 2>&1; do
      echo "Waiting for apt lock..."
      sleep 5
    done

    dpkg --configure -a || true
    sleep 5

    modprobe overlay
    modprobe br_netfilter

    cat <<EOF > /etc/modules-load.d/k8s.conf
    overlay
    br_netfilter
    EOF

    cat <<EOF > /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
    EOF
    sysctl --system

    apt_install() {
      for i in 1 2 3 4 5; do
        apt-get "$@" && return 0
        echo "apt-get failed (attempt $i), retrying in 15s..."
        sleep 15
      done
      return 1
    }

    apt_install update
    apt_install install -y apt-transport-https ca-certificates curl gnupg python3
  EOT

  # ── ssh-node-1 cloud-init ──────────────────────────────────────────────────
  # Installs the Teleport node agent and configures it to join the cluster
  # automatically using the AWS IAM join method. No static tokens or secrets.
  # The node calls sts:GetCallerIdentity; Teleport verifies the signed response
  # matches the allow rules in the ssh-node-iam-token join token.
  ssh_node_userdata = <<-EOT
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/cloud-init-teleport.log) 2>&1

    export DEBIAN_FRONTEND=noninteractive

    # ── Wait for apt lock ────────────────────────────────────────────────────
    systemctl disable --now unattended-upgrades || true
    systemctl disable --now apt-daily.timer || true
    systemctl disable --now apt-daily-upgrade.timer || true

    systemd-run --property="After=apt-daily.service apt-daily-upgrade.service" \
      --wait /bin/true 2>/dev/null || true

    while fuser /var/lib/dpkg/lock-frontend \
                /var/lib/apt/lists/lock \
                /var/lib/dpkg/lock \
                /var/cache/apt/archives/lock >/dev/null 2>&1; do
      echo "Waiting for apt lock..."
      sleep 5
    done

    dpkg --configure -a || true
    sleep 5

    apt_install() {
      for i in 1 2 3 4 5; do
        apt-get "$@" && return 0
        echo "apt-get failed (attempt $i), retrying in 15s..."
        sleep 15
      done
      return 1
    }

    apt_install update
    apt_install install -y curl

    # ── Install Teleport Enterprise ──────────────────────────────────────────
    curl -fsSL https://cdn.teleport.dev/install-v18.7.1.sh | bash -s 18.7.1 enterprise

    # ── Write Teleport node config ───────────────────────────────────────────
    # join_method: iam  — uses sts:GetCallerIdentity, no static token
    # token:            — must match the join token name created by Ansible
    # labels:           — 'team' must match Okta group for RBAC scoping
    cat <<EOF > /etc/teleport.yaml
    version: v3
    teleport:
      nodename: ssh-node-1
      data_dir: /var/lib/teleport
      log:
        output: stderr
        severity: INFO
      join_params:
        method: iam
        token_name: ssh-node-iam-token
      proxy_server: grant-tam-teleport.gvteleport.com:443

    auth_service:
      enabled: false

    proxy_service:
      enabled: false

    ssh_service:
      enabled: true
      labels:
        team: platform
        env: demo
        node: ssh-node-1
      commands:
        - name: hostname
          command: [hostname]
          period: 1m0s
    EOF

    # ── Enable and start Teleport ────────────────────────────────────────────
    systemctl enable teleport
    systemctl start teleport

    echo "ssh-node-1 Teleport agent started — joining via AWS IAM join method"
  EOT
}

# ─── EC2 Instances ────────────────────────────────────────────────────────────

resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id
  source_dest_check      = false
  private_ip             = var.master_ip
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
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
  instance_type          = var.instance_type
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id
  source_dest_check      = false
  private_ip             = var.node1_ip
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
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
  instance_type          = var.instance_type
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id
  source_dest_check      = false
  private_ip             = var.node2_ip
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data              = local.worker_userdata

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-node2"
  })

  volume_tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-node2-volume"
  })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "master_public_ip"  { value = aws_instance.master.public_ip }
output "master_private_ip" { value = aws_instance.master.private_ip }
output "node1_private_ip"  { value = aws_instance.node1.private_ip }
output "node2_private_ip"  { value = aws_instance.node2.private_ip }
output "private_key_pem" {
  value     = nonsensitive(tls_private_key.main.private_key_pem)
  sensitive = false
}
output "private_key_path"  { value = local_sensitive_file.private_key.filename }
output "ubuntu_ami_id"     { value = data.aws_ami.ubuntu.id }
output "ubuntu_ami_name"   { value = data.aws_ami.ubuntu.name }
