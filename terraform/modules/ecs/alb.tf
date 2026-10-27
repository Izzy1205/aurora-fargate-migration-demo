# Demo ALB: HTTP only, locked to the CIDRs in alb_ingress_cidrs.
# Production: HTTPS listener with an ACM cert, HTTP redirect, access logs.
resource "aws_lb" "this" {
  # The WAF is attached in modules/waf, called from layers/app. checkov's
  # graph doesn't follow the association across the module boundary.
  #checkov:skip=CKV2_AWS_28:web ACL associated by modules/waf in the same unit
  name                       = "${var.name_prefix}-alb"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [var.alb_security_group_id]
  drop_invalid_header_fields = true
  enable_deletion_protection = false # demo only
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.name_prefix}-app"
  vpc_id               = var.vpc_id
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "ip"
  deregistration_delay = 10 # short drain so demo deploys finish quickly

  # /health does not touch the database, so ALB checks never wake a paused
  # Aurora cluster.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
