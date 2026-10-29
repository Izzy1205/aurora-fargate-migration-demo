# Email when an Aurora backup or its cross-Region copy fails.
#
# An EventBridge rule, not a CloudWatch alarm. AWS Backup sends a "Backup
# Job State Change" and a "Copy Job State Change" event for every job, in
# the home region, and both carry the source cluster ARN. So one rule here
# catches both, scoped to this env's cluster. The AWS/Backup metrics would
# also work, but copy job metrics are keyed by the destination vault and
# land in the region the job runs in, which is harder to pin down. Events
# from AWS services to the default bus are free.
#
# Not a CloudWatch alarm, so the README's alarm count doesn't change.
# EventBridge delivers these events on a best effort basis, so a missing
# email doesn't prove a job worked. The AWS Backup console's job list is
# the source of truth.
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

  # A readable line instead of the raw event JSON.
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
