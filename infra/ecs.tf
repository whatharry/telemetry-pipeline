resource "aws_ecr_repository" "ingest" {
  name                 = "${var.project}-ingest"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep only the last 10 images. Without this, ECR grows forever and quietly
# becomes the largest line on the bill for a project this small.
resource "aws_ecr_lifecycle_policy" "ingest" {
  repository = aws_ecr_repository.ingest.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # Container Insights bills per metric; off for a demo.
  }
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/ecs/${var.project}-ingest"
  retention_in_days = var.log_retention_days
}

# --- IAM -------------------------------------------------------------------
# Two roles, deliberately separate:
#   execution_role -- what ECS itself needs (pull image, write logs, read secret)
#   task_role      -- what the application code may call at runtime
# The app needs no AWS APIs, so its task role stays empty. Collapsing these into
# one over-privileged role is the most common mistake in ECS setups.

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.project}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "read_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db_password.arn]
  }
}

resource "aws_iam_role_policy" "execution_secret" {
  name   = "${var.project}-read-db-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_secret.json
}

resource "aws_iam_role" "task" {
  name               = "${var.project}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# --- task definition -------------------------------------------------------

resource "aws_ecs_task_definition" "ingest" {
  family                   = "${var.project}-ingest"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ingest_cpu
  memory                   = var.ingest_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "ingest"
    image     = "${aws_ecr_repository.ingest.repository_url}:latest"
    essential = true

    portMappings = [{ containerPort = 3000, protocol = "tcp" }]

    environment = [
      { name = "PGHOST", value = aws_db_instance.main.address },
      { name = "PGPORT", value = "5432" },
      { name = "PGUSER", value = "telemetry" },
      { name = "PGDATABASE", value = "telemetry" },
      { name = "PG_POOL_MAX", value = "10" },
      { name = "MAX_BATCH", value = "1000" },
      { name = "NODE_ENV", value = "production" },
    ]

    # Injected by ECS at start time from Secrets Manager -- never stored in the
    # task definition itself.
    secrets = [{
      name      = "PGPASSWORD"
      valueFrom = aws_secretsmanager_secret.db_password.arn
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ingest.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "node -e \"require('http').get('http://localhost:3000/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
  }])
}

resource "aws_ecs_service" "ingest" {
  name            = "${var.project}-ingest"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.ingest.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # required without a NAT gateway, to reach ECR
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ingest.arn
    container_name   = "ingest"
    container_port   = 3000
  }

  # Give the task time to connect to RDS before the ALB starts failing it.
  health_check_grace_period_seconds = 60

  depends_on = [aws_lb_listener.http]

  lifecycle {
    # CI updates the task definition on deploy; Terraform should not fight it.
    ignore_changes = [task_definition]
  }
}
