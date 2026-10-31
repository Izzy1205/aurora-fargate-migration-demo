# The SSN token service as its own ECS service, so a later PR can take the
# key, pepper and vault login away from the app. Same image as the app, run
# as demo_app.vault (only /health and /ssn/*). No load balancer: the app
# reaches it by private DNS from Cloud Map, and its security group lets in
# only the app tasks.
#
# Everything here is new. Nothing in modules/ecs or modules/network changes,
# so applying this adds resources and replaces nothing.

data "aws_region" "current" {}

locals {
  name      = "${var.name_prefix}-ssn-vault"
  container = "ssn-vault"
}

resource "aws_cloudwatch_log_group" "vault" {
  name              = "/ecs/${var.name_prefix}/ssn-vault"
  retention_in_days = var.log_retention_days
}

# Fixed at 256 CPU / 512 MB like the app. The task count is per environment
# (ssn_vault_desired_count in env.hcl), set by deploy.yml.
resource "aws_ecs_task_definition" "vault" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = local.container
    image                  = var.image
    essential              = true
    readonlyRootFilesystem = true
    # Vault-only entry point. No --proxy-headers: nothing proxies to it.
    command      = ["sh", "-c", "exec uvicorn demo_app.vault:app --host 0.0.0.0 --port $${PORT} --no-access-log"]
    portMappings = [{ containerPort = var.port, protocol = "tcp" }]
    # No secrets. The key, pepper and IAM auth DB login all come from the
    # task role at runtime (see app/src/demo_app/ssn/config.py).
    environment = [
      { name = "DB_HOST", value = var.db_host },
      { name = "DB_PORT", value = tostring(var.db_port) },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_SSLMODE", value = "require" },
      { name = "PORT", value = tostring(var.port) },
    ]
    # /health never touches AWS or the database. Cloud Map only returns
    # tasks that pass this.
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import os,urllib.request;urllib.request.urlopen('http://127.0.0.1:'+os.environ['PORT']+'/health',timeout=2)\" || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.vault.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "ssn-vault"
      }
    }
  }])
}

# Like the app service: Terraform creates it at 0 tasks and leaves the task
# definition and count to deploy.yml, which registers a revision pinned by
# digest and scales to ssn_vault_desired_count.
resource "aws_ecs_service" "vault" {
  name                               = local.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.vault.arn
  desired_count                      = 0
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  availability_zone_rebalancing      = "ENABLED"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.vault.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.vault.arn
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}
