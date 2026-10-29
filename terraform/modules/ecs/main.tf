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
    ], var.app_environment)
    # Injected by the ECS agent at task start from the app login secret,
    # which only gets row access. The values never pass through Terraform,
    # GitHub or the image.
    secrets = [
      { name = "DB_USER", valueFrom = "${var.app_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.app_secret_arn}:password::" },
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
    # The Flyway login owns the schema. It is not the master user.
    secrets = [
      { name = "FLYWAY_USER", valueFrom = "${var.migrator_secret_arn}:username::" },
      { name = "FLYWAY_PASSWORD", valueFrom = "${var.migrator_secret_arn}:password::" },
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

# One-off task that creates the app and Flyway logins and sets their
# passwords. It is the only thing that reads the master secret, and CI runs
# it before Flyway on every deploy. It is safe to re-run: it only creates
# what is missing and re-applies the same grants. Same image as Flyway, with
# a different entrypoint (db/logins/db-logins.sh).
resource "aws_ecs_task_definition" "db_logins" {
  family                   = "${var.name_prefix}-db-logins"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution["db-logins"].arn
  task_role_arn            = aws_iam_role.task["db-logins"].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = "db-logins"
    image                  = var.migration_image
    essential              = true
    readonlyRootFilesystem = true
    entryPoint             = ["/flyway/logins/db-logins.sh"]
    environment = [
      { name = "PGHOST", value = var.db_host },
      { name = "PGPORT", value = tostring(var.db_port) },
      { name = "PGDATABASE", value = var.db_name },
      { name = "PGSSLMODE", value = "require" },
      { name = "APP_DB_USER", value = var.app_username },
      { name = "MIGRATOR_DB_USER", value = var.migrator_username },
    ]
    secrets = [
      { name = "PGUSER", valueFrom = "${var.master_secret_arn}:username::" },
      { name = "PGPASSWORD", valueFrom = "${var.master_secret_arn}:password::" },
      { name = "APP_DB_PASSWORD", valueFrom = "${var.app_secret_arn}:password::" },
      { name = "MIGRATOR_DB_PASSWORD", valueFrom = "${var.migrator_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.migration.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "db-logins"
      }
    }
  }])
}

# Starts at zero tasks. CI picks the revision and scales it to 2 after the
# migration, so Terraform ignores those fields.
#
# Fargate spreads a service's tasks across the AZs of its subnets, so with two
# private subnets the 2 tasks land one per AZ. Rebalancing moves them back if
# an AZ outage left both in one AZ. During a deploy ECS starts 2 new tasks
# before stopping the old ones (100% min healthy, 200% max).
resource "aws_ecs_service" "app" {
  name                               = "${var.name_prefix}-app"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = 0
  launch_type                        = "FARGATE"
  health_check_grace_period_seconds  = 30
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  availability_zone_rebalancing      = "ENABLED"

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
