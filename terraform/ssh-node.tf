# ─── ssh-node-1: Standalone Teleport SSH node ─────────────────────────────────
# Ubuntu t2.small that auto-enrolls into the Teleport cluster using the
# AWS IAM join method. No static tokens — the node proves its identity via
# sts:GetCallerIdentity signed by AWS, which Teleport verifies against the
# allow rules in the IAM join token.

# ─── IAM Role for ssh-node-1 ─────────────────────────────────────────────────
# Separate role from the K8s cluster nodes — minimal permissions,
# only what Teleport node agent needs to perform the IAM join.

resource "aws_iam_role" "ssh_node" {
  name = "${var.training_prefix}-ssh-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-ssh-node-role"
  })
}

# The Teleport IAM join method requires the node to call sts:GetCallerIdentity.
# This is implicit via the instance metadata — no explicit policy needed for that.
# ec2:DescribeInstances is required for Teleport to read instance tags as labels.
resource "aws_iam_role_policy" "ssh_node_teleport" {
  name = "${var.training_prefix}-ssh-node-teleport-policy"
  role = aws_iam_role.ssh_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TeleportNodeLabels"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ssh_node" {
  name = "${var.training_prefix}-ssh-node-profile"
  role = aws_iam_role.ssh_node.name
}

# ─── ssh-node-1 EC2 instance ─────────────────────────────────────────────────

resource "aws_instance" "ssh_node_1" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.small"
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id
  iam_instance_profile   = aws_iam_instance_profile.ssh_node.name
  user_data              = local.ssh_node_userdata

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-ssh-node-1"
    # 'team' tag is imported by Teleport as a node label.
    # Must match the Okta group name for ssh-access/ssh-root-access RBAC scoping.
    team        = "platform"
    description = "Teleport SSH demo node — IAM auto-enrollment"
  })

  volume_tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-ssh-node-1-volume"
  })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "ssh_node_1_public_ip" {
  value       = aws_instance.ssh_node_1.public_ip
  description = "Public IP of ssh-node-1"
}

output "ssh_node_1_private_ip" {
  value       = aws_instance.ssh_node_1.private_ip
  description = "Private IP of ssh-node-1"
}
