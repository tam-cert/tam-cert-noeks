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
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.teleport_sessions.arn,
        "${aws_s3_bucket.teleport_sessions.arn}/*"
      ]
    }]
  })
}

# ─── RDS IAM authentication policy ───────────────────────────────────────────
# Grants EC2 nodes the ability to obtain IAM auth tokens for RDS.
# The teleport DB user must have the rds_iam role granted in PostgreSQL.
# No password is used — authentication is via short-lived IAM tokens only.

resource "aws_iam_role_policy" "rds_iam_auth" {
  name = "${var.training_prefix}-rds-iam-auth-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RDSConnect"
        Effect = "Allow"
        Action = "rds-db:connect"
        Resource = [
          # Wildcard covers both teleport_backend and teleport_audit db users
          "arn:aws:rds-db:us-west-2:*:dbuser:*/*"
        ]
      },
      {
        Sid    = "RDSDescribe"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:ModifyDBInstance"
        ]
        Resource = "*"
      }
    ]
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
# IAM database authentication is enabled — no password auth for Teleport.
# The 'teleport' DB user must be granted the rds_iam role in PostgreSQL
# (handled by the Ansible teleport role post-install task).

resource "aws_db_instance" "teleport" {
  identifier            = "${var.training_prefix}-pg-1"
  engine                = "postgres"
  engine_version        = "17.6"
  instance_class        = "db.t3.medium"
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "teleport_backend"
  username = "teleport_admin"
  password = var.db_password
  port     = 5432

  # Enable IAM authentication — Teleport auth server connects via IAM token,
  # not password. The master password above is only used for initial DB setup.
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  multi_az                = false
  publicly_accessible     = false
  deletion_protection     = false
  skip_final_snapshot     = true
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-pg-1"
  })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "rds_endpoint" {
  value = aws_db_instance.teleport.endpoint
}

output "rds_address" {
  value = aws_db_instance.teleport.address
}

# ─── RDS teleport user bootstrap ─────────────────────────────────────────────
# Runs inside the VPC via SSH to the master EC2 node.
# Generates an IAM auth token using the EC2 instance role (which has
# rds-db:connect), then uses it to create the teleport PostgreSQL user
# and grant rds_iam. No passwords stored anywhere.
#
# Note: teleport_admin (master user) cannot use IAM auth — AWS only supports
# IAM auth for non-master users. We use the master password here once, via
# remote-exec over SSH, purely to bootstrap the teleport IAM user.

resource "null_resource" "rds_bootstrap" {
  triggers = {
    rds_instance_id = aws_db_instance.teleport.id
  }

  connection {
    type        = "ssh"
    host        = aws_instance.master.public_ip
    user        = "ubuntu"
    private_key = tls_private_key.main.private_key_pem
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get install -y postgresql-client 2>&1 | tail -1",
      "curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /tmp/rds-ca.pem",
      <<-SCRIPT
      export PGPASSWORD='${var.db_password}'
      export PGSSLROOTCERT=/tmp/rds-ca.pem
      export PGSSLMODE=verify-full
      RDS=${aws_db_instance.teleport.address}

      psql "postgresql://teleport_admin@$RDS:5432/teleport_backend" -c "
        DO \$\$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'teleport') THEN
            CREATE USER teleport;
          END IF;
        END
        \$\$;
        GRANT rds_iam TO teleport;
        GRANT ALL PRIVILEGES ON DATABASE teleport_backend TO teleport;
      "
      psql "postgresql://teleport_admin@$RDS:5432/postgres" -c "
        SELECT 'CREATE DATABASE teleport_audit'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'teleport_audit')\gexec
      "
      psql "postgresql://teleport_admin@$RDS:5432/teleport_audit" -c "
        GRANT ALL PRIVILEGES ON DATABASE teleport_audit TO teleport;
      "
      SCRIPT
    ]
  }

  depends_on = [
    aws_instance.master,
    aws_db_instance.teleport
  ]
}
