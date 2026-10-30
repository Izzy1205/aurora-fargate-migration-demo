# Regional WAF in front of the ALB. Default allow, then AWS managed rule
# groups and per-IP rate limits (a tight one on /ssn/reveal) decide what
# gets blocked.
#
# ALB health checks to /health go straight from the ALB nodes to the
# targets. They never pass through the web ACL, so no rule here can mark a
# task unhealthy.
#
# count_only flips every rule to count: requests are logged and show up in
# the CountedRequests metric, nothing is blocked. Use it for a first rollout,
# read the logs for false positives, then switch it off.

locals {
  # count_only swaps block for count. Managed rule groups take it through
  # override_action, our own rate rule through action.
  managed_override = var.count_only ? "count" : "none"
  rate_action      = var.count_only ? "count" : "block"
}

resource "aws_wafv2_web_acl" "this" {
  # Log4j is blocked by KnownBadInputs whenever count_only is false (the
  # testing default). checkov can't resolve the variable, and count-only
  # first rollouts are on purpose.
  #checkov:skip=CKV_AWS_192:blocks when count_only = false; count is a deliberate first-rollout mode
  name        = "${var.name_prefix}-alb"
  description = "${var.name_prefix} ALB: managed rules and a per-IP rate limit"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Lower priority runs first. The cheap IP checks go before the bigger rule
  # sets.
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

  # Reveal turns a token back into an SSN, so it gets a much tighter cap than
  # the rest of the site. A person reveals one record at a time; a script
  # walking tokens does not. Blocked callers get a 429. This only slows a
  # drain: the real limits are the actor, reason and audit row on each
  # reveal, and later a per-actor limit in the app.
  rule {
    name     = "rate-limit-ssn-reveal"
    priority = 15

    action {
      dynamic "block" {
        for_each = local.rate_action == "block" ? [1] : []
        content {
          custom_response {
            response_code = 429
          }
        }
      }
      dynamic "count" {
        for_each = local.rate_action == "count" ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.reveal_rate_limit
        evaluation_window_sec = 60
        aggregate_key_type    = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/ssn/reveal"
            positional_constraint = "STARTS_WITH"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-rate-limit-ssn-reveal"
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

  # Includes the Log4j (CVE-2021-44228) rules.
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

  # The app sits on Postgres.
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
