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
        "s3:GetObjectVersion",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:ListBucketVersions",
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

# ─── Identity Activity Center Infrastructure ─────────────────────────────────
# Supports Teleport Access Graph Identity Activity Center.
# Resources: KMS key, long-term S3 bucket, transient S3 bucket,
#            AWS Glue database + table, Amazon Athena workgroup,
#            IAM permissions for the EC2 role.

data "aws_caller_identity" "current" {}

# ── KMS key for encrypting S3 objects and SQS messages ───────────────────────

resource "aws_kms_key" "identity_activity" {
  description             = "${var.training_prefix} Identity Activity Center encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow EC2 Role"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ec2.arn
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity-kms"
  })
}

resource "aws_kms_alias" "identity_activity" {
  name          = "alias/${var.training_prefix}-identity-activity"
  target_key_id = aws_kms_key.identity_activity.key_id
}

# ── Long-term S3 bucket (Parquet audit event storage) ─────────────────────────

resource "aws_s3_bucket" "identity_activity_long" {
  bucket        = "${var.training_prefix}-identity-activity-long"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity-long"
  })
}

resource "aws_s3_bucket_versioning" "identity_activity_long" {
  bucket = aws_s3_bucket.identity_activity_long.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "identity_activity_long" {
  bucket = aws_s3_bucket.identity_activity_long.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.identity_activity.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "identity_activity_long" {
  bucket                  = aws_s3_bucket.identity_activity_long.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Transient S3 bucket (Athena query results + large files) ──────────────────

resource "aws_s3_bucket" "identity_activity_transient" {
  bucket        = "${var.training_prefix}-identity-activity-transient"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity-transient"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "identity_activity_transient" {
  bucket = aws_s3_bucket.identity_activity_transient.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.identity_activity.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "identity_activity_transient" {
  bucket                  = aws_s3_bucket.identity_activity_transient.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "identity_activity_transient" {
  bucket = aws_s3_bucket.identity_activity_transient.id
  rule {
    id     = "expire-transient-objects"
    status = "Enabled"
    expiration {
      days = 7
    }
    filter {}
  }
}

# ── AWS Glue catalog database ─────────────────────────────────────────────────
# Only the database is created here — Access Graph creates and manages the table
# schema itself on first startup. Pre-creating the table causes Athena query
# failures due to empty/mismatched column definitions.

resource "aws_glue_catalog_database" "identity_activity" {
  name        = "${var.training_prefix}-identity-activity"
  description = "Teleport Identity Activity Center audit event catalog"
}

# ── Amazon Athena workgroup ───────────────────────────────────────────────────

resource "aws_athena_workgroup" "identity_activity" {
  name        = "${var.training_prefix}-identity-activity"
  description = "Teleport Identity Activity Center query workgroup"
  force_destroy = true

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.identity_activity_transient.bucket}/results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.identity_activity.arn
      }
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity"
  })
}

# ── IAM permissions for Identity Activity Center ──────────────────────────────

resource "aws_iam_role_policy" "identity_activity" {
  name = "${var.training_prefix}-identity-activity-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3LongTermAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.identity_activity_long.arn,
          "${aws_s3_bucket.identity_activity_long.arn}/*"
        ]
      },
      {
        Sid    = "S3TransientAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.identity_activity_transient.arn,
          "${aws_s3_bucket.identity_activity_transient.arn}/*"
        ]
      },
      {
        Sid    = "GlueAccess"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetPartitions",
          "glue:BatchCreatePartition",
          "glue:CreatePartition",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable"
        ]
        Resource = [
          "arn:aws:glue:us-west-2:${data.aws_caller_identity.current.account_id}:catalog",
          aws_glue_catalog_database.identity_activity.arn,
          "arn:aws:glue:us-west-2:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.identity_activity.name}/*"
        ]
      },
      {
        Sid    = "AthenaAccess"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup"
        ]
        Resource = aws_athena_workgroup.identity_activity.arn
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.identity_activity.arn
      },
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = "arn:aws:sqs:us-west-2:${data.aws_caller_identity.current.account_id}:grantvoss-q-1"
      }
    ]
  })
}

# ─── Identity Activity Center Outputs ────────────────────────────────────────

output "identity_activity_long_bucket" {
  value       = aws_s3_bucket.identity_activity_long.bucket
  description = "S3 bucket for Identity Activity Center long-term storage"
}

output "identity_activity_transient_bucket" {
  value       = aws_s3_bucket.identity_activity_transient.bucket
  description = "S3 bucket for Identity Activity Center transient storage"
}

output "identity_activity_kms_arn" {
  value       = aws_kms_key.identity_activity.arn
  description = "KMS key ARN for Identity Activity Center"
}

output "identity_activity_workgroup" {
  value       = aws_athena_workgroup.identity_activity.name
  description = "Athena workgroup for Identity Activity Center"
}
