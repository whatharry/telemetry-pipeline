# RDS Postgres.
#
# Note on TimescaleDB: RDS does NOT offer the TimescaleDB extension. The schema
# therefore degrades to plain Postgres here -- hypertables and continuous
# aggregates are not created. Three honest options, documented in the README:
#
#   1. Timescale Cloud, peered to this VPC (what a real deployment would do)
#   2. TimescaleDB in its own Fargate task with EFS (cheap, single-AZ, no HA)
#   3. Plain RDS + materialised views refreshed on a schedule (what this uses)
#
# Option 3 keeps the deployment inside the free tier and still exercises the
# thing this stack is demonstrating: managed database, VPC isolation, secrets
# handling, and a service that survives a restart.

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db"
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project}-db"
  engine         = "postgres"
  engine_version = "16"

  # db.t4g.micro is free-tier eligible for 12 months on a new account.
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "telemetry"
  username = "telemetry"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  # Both false deliberately: this is a demo that gets destroyed. Production would
  # enable multi_az and deletion_protection, and set skip_final_snapshot = false.
  multi_az = false

  performance_insights_enabled = false
  apply_immediately            = true
}

# The password never lands in a task definition, where anyone with
# ecs:DescribeTaskDefinition could read it. It goes to Secrets Manager and the
# task pulls it at start.
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project}/db-password"
  recovery_window_in_days = 0 # demo: allow immediate re-create after destroy
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}
