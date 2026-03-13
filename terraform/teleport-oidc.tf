# ─── Teleport AWS OIDC Integration ───────────────────────────────────────────
# Registers Teleport as an OIDC identity provider in AWS IAM and creates
# the IAM role that Teleport assumes to access AWS resources.

locals {
  teleport_cluster_name = "grant-tam-teleport.gvteleport.com"
  teleport_oidc_url     = "https://grant-tam-teleport.gvteleport.com"
}

# ─── AWS IAM OIDC Provider ────────────────────────────────────────────────────
# Registers the Teleport cluster as a trusted OIDC identity provider in AWS.

resource "aws_iam_openid_connect_provider" "teleport" {
  url = local.teleport_oidc_url

  client_id_list = [
    "discover.teleport",
  ]

  # AWS retrieves the thumbprint automatically for well-known providers.
  # An empty list instructs AWS to use its own trusted CA library.
  thumbprint_list = []

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-oidc-provider"
  })
}

# ─── IAM Role for Teleport OIDC Integration ───────────────────────────────────

resource "aws_iam_role" "teleport_oidc" {
  name = "grant-tam-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.teleport.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.teleport_cluster_name}:aud" = "discover.teleport"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "grant-tam-oidc-role"
  })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "teleport_oidc_role_arn" {
  value       = aws_iam_role.teleport_oidc.arn
  description = "ARN of the IAM role used by the Teleport AWS OIDC integration"
}

output "teleport_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.teleport.arn
  description = "ARN of the AWS IAM OIDC provider for Teleport"
}
