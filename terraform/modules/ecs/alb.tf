# Demo ALB, locked to the CIDRs in alb_ingress_cidrs. HTTPS on 443 with the
# cert from tls.tf; port 80 only redirects to it. Still not done: access
# logs, and TLS from the ALB to the tasks (the target group is HTTP).
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

  # Already the AWS default. Set here so a later change shows up in review.
  # "defensive" blocks requests that are a known desync risk and keeps
  # serving the rest; "strictest" also drops odd but harmless ones.
  desync_mitigation_mode = "defensive"
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

# Port 80 only sends clients to HTTPS. Same resource as the old forward
# listener, so this is an in-place update, not a replace.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      host        = "#{host}"
      path        = "/#{path}"
      query       = "#{query}"
      status_code = "HTTP_301"
    }
  }
}

# TLS 1.3 and 1.2 only, forward secret ciphers only (ECDHE and TLS 1.3), with
# hybrid post-quantum key exchange for clients that offer it. AWS's current
# recommendation and the console default:
# https://docs.aws.amazon.com/elasticloadbalancing/latest/application/describe-ssl-policies.html
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = local.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
