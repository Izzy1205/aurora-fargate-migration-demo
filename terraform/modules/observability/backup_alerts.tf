# Emails on a failed backup or copy. Best effort, so check the Backup console too.
locals {
  aurora_cluster_arn = "arn:${data.aws_partition.current.partition}:rds:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster:${var.aurora_cluster_identifier}"
}

resource "aws_cloudwatch_event_rule" "backup_failed" {
  name        = "${var.name_prefix}-aurora-backup-failed"
  description = "Aurora backup or cross-Region copy failed, aborted or expired."

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Backup Job State Change", "Copy Job State Change"]
    detail = {
      state       = ["FAILED", "ABORTED", "EXPIRED"]
      resourceArn = [local.aurora_cluster_arn]
    }
  })
}

resource "aws_cloudwatch_event_target" "backup_failed" {
  rule      = aws_cloudwatch_event_rule.backup_failed.name
  target_id = "alarm-topic"
  arn       = aws_sns_topic.alarms.arn

  input_transformer {
    input_paths = {
      type     = "$.detail-type"
      state    = "$.detail.state"
      resource = "$.detail.resourceArn"
      time     = "$.time"
    }
    input_template = "\"${var.name_prefix}: <type> is <state> for <resource> at <time> UTC. Check the AWS Backup jobs page for the reason.\""
  }
}
