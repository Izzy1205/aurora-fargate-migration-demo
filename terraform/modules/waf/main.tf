# Default allow. Managed rules and a per-IP rate limit do the blocking.
# count_only logs instead of blocking, for a first rollout.

locals {
  managed_override = var.count_only ? "count" : "none"
  rate_action      = var.count_only ? "count" : "block"
}

resource "aws_wafv2_web_acl" "this" {
  # checkov can't resolve count_only. KnownBadInputs blocks Log4j when it's false.
  #checkov:skip=CKV_AWS_192:blocks when count_only = false; count is a deliberate first-rollout mode
  name        = "${var.name_prefix}-alb"
  description = "${var.name_prefix} ALB: managed rules and a per-IP rate limit"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Lower priority runs first, so cheap IP checks go before the big rule sets.
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 10

    override_action {
      dynamic "none" {
        for_each = local.managed_override == "none" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.managed_override == "count" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 20

    action {
      dynamic "block" {
        for_each = local.rate_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.rate_action == "count" ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 30

    override_action {
      dynamic "none" {
        for_each = local.managed_override == "none" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.managed_override == "count" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Includes the Log4j rules.
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 40

    override_action {
      dynamic "none" {
        for_each = local.managed_override == "none" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.managed_override == "count" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 50

    override_action {
      dynamic "none" {
        for_each = local.managed_override == "none" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.managed_override == "count" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-alb"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}
