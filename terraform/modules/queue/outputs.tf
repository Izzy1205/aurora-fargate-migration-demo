output "queue_url" {
  description = "Main queue URL, passed to the app as PAYMENT_QUEUE_URL."
  value       = aws_sqs_queue.main.id
}

output "queue_arn" {
  description = "Main queue ARN."
  value       = aws_sqs_queue.main.arn
}

output "queue_name" {
  description = "Main queue name, the QueueName dimension in AWS/SQS."
  value       = aws_sqs_queue.main.name
}

output "dlq_name" {
  description = "Dead letter queue name."
  value       = aws_sqs_queue.dlq.name
}

output "dlq_arn" {
  description = "Dead letter queue ARN."
  value       = aws_sqs_queue.dlq.arn
}

output "kms_key_arn" {
  description = "Key both queues are encrypted with."
  value       = aws_kms_key.queue.arn
}

output "task_policy_json" {
  description = "Least privilege policy for a task that sends and consumes payment requests."
  value       = data.aws_iam_policy_document.task.json
}
