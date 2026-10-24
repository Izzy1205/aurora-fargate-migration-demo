data "aws_region" "current" {}

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # costs extra; turn on outside a demo
  }
}

locals {
  db_env = [
    { name = "DB_HOST", value = var.db_host },
    { name = "DB_PORT", value = tostring(var.db_port) },
    { name = "DB_NAME", value = var.db_name },
  ]
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution["app"].arn
  task_role_arn            = aws_iam_role.task["app"].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = "app"
    image                  = var.app_image
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = var.app_port, protocol = "tcp" }]
    environment = concat(local.db_env, [
      { name = "DB_SSLMODE", value = "require" },
      { name = "PORT", value = tostring(var.app_port) },
    ])
    # Injected by the ECS agent at task start from the RDS-managed secret.
    # The values never pass through Terraform, GitHub or the image.
    secrets = [
      { name = "DB_USER", valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "migration" {
  family                   = "${var.name_prefix}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution["migrate"].arn
  task_role_arn            = aws_iam_role.task["migrate"].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "migrate"
    image     = var.migration_image
    essential = true
    command   = ["migrate"]
    environment = [
      { name = "FLYWAY_URL", value = "jdbc:postgresql://${var.db_host}:${var.db_port}/${var.db_name}?sslmode=require" },
      # Aurora may be paused at zero ACUs; give it time to resume.
      { name = "FLYWAY_CONNECT_RETRIES", value = "12" },
      { name = "FLYWAY_CLEAN_DISABLED", value = "true" },
      { name = "FLYWAY_VALIDATE_MIGRATION_NAMING", value = "true" },
    ]
    secrets = [
      { name = "FLYWAY_USER", valueFrom = "${var.db_secret_arn}:username::" },
      { name = "FLYWAY_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.migration.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "migrate"
      }
    }
  }])
}

# Starts at zero tasks. CI picks the revision and scales it up after the
# migration, so Terraform ignores those fields.
resource "aws_ecs_service" "app" {
  name                              = "${var.name_prefix}-app"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.app.arn
  desired_count                     = 0
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 30

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.app_port
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http]
}
