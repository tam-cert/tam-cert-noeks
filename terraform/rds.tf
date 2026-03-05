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

# Grant EC2 instances access to the session recordings bucket
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
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.teleport_sessions.arn,
        "${aws_s3_bucket.teleport_sessions.arn}/*"
      ]
    }]
  })
}

# ─── Store DB password in AWS Secrets Manager ────────────────────────────────

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.training_prefix}/teleport/db-password"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-db-password"
  })
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}

# ─── RDS Subnet Group ─────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name        = "${var.training_prefix}-db-subnet-group"
  description = "Subnet group for Teleport RDS PostgreSQL"
  subnet_ids  = [aws_subnet.main.id, aws_subnet.secondary.id]

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-db-subnet-group"
  })
}

# Secondary subnet in a different AZ required by RDS
resource "aws_subnet" "secondary" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "172.49.21.0/24"
  availability_zone = "us-west-2b"

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-subnet-2"
  })
}

# ─── RDS Security Group ───────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name        = "${var.training_prefix}-rds-SG"
  description = "Allow PostgreSQL access from Kubernetes nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from cluster nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.main.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-rds-SG"
  })
}

# ─── RDS Parameter Group ──────────────────────────────────────────────────────

resource "aws_db_parameter_group" "main" {
  name        = "${var.training_prefix}-pg17"
  family      = "postgres17"
  description = "Parameter group for Teleport PostgreSQL 17"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-pg17"
  })
}

# ─── RDS PostgreSQL Instance ──────────────────────────────────────────────────

resource "aws_db_instance" "teleport" {
  identifier              = "grant-tam-pg-1"
  engine                  = "postgres"
  engine_version          = "17.6"
  instance_class          = "db.t3.medium"
  allocated_storage       = 20
  max_allocated_storage   = 100
  storage_type            = "gp3"
  storage_encrypted       = true

  db_name                 = "teleport_backend"
  username                = "teleport"
  password                = var.db_password
  port                    = 5432

  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  parameter_group_name    = aws_db_parameter_group.main.name

  multi_az                = false
  publicly_accessible     = false
  deletion_protection     = false
  skip_final_snapshot     = true
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  tags = merge(local.common_tags, {
    Name = "grant-tam-pg-1"
  })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "rds_endpoint" {
  value = aws_db_instance.teleport.endpoint
}

output "rds_address" {
  value = aws_db_instance.teleport.address
}
