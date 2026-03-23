# ─── S3 Bucket for Teleport Session Recordings ───────────────────────────────

resource "aws_s3_bucket" "teleport_sessions" {
  bucket        = "${var.training_prefix}-teleport-sessions"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-sessions"
  })
}

resource "aws_s3_bucket_versioning" "teleport_sessions" {
  bucket = aws_s3_bucket.teleport_sessions.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "teleport_sessions" {
  bucket = aws_s3_bucket.teleport_sessions.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "teleport_sessions" {
  bucket                  = aws_s3_bucket.teleport_sessions.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── S3 session recordings access ────────────────────────────────────────────

resource "aws_iam_role_policy" "s3_sessions" {
  name = "${var.training_prefix}-s3-sessions-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:CreateMultipartUpload",
        "s3:UploadPart",
        "s3:CompleteMultipartUpload",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ]
      Resource = [
        aws_s3_bucket.teleport_sessions.arn,
        "${aws_s3_bucket.teleport_sessions.arn}/*"
      ]
    }]
  })
}

# ─── Teleport license secret ──────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "teleport_license" {
  name                    = "${var.training_prefix}/teleport/license"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-license"
  })
}

resource "aws_secretsmanager_secret_version" "teleport_license" {
  secret_id     = aws_secretsmanager_secret.teleport_license.id
  secret_string = var.teleport_license
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "sessions_bucket" {
  value       = aws_s3_bucket.teleport_sessions.bucket
  description = "S3 bucket for Teleport session recordings"
}
