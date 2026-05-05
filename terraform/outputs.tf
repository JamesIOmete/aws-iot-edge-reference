# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
#
# Values the operator needs immediately after terraform apply:
#   - IoT endpoint → goes into the simulator's IOT_ENDPOINT env var
#   - DynamoDB table name → useful for manual queries and debugging
#   - Dashboard URL → direct link to the operational view
#   - SNS topic ARN → if wiring in additional subscriptions (PagerDuty, etc.)
# ---------------------------------------------------------------------------

data "aws_iot_endpoint" "this" {
  endpoint_type = "iot:Data-ATS"
}

output "iot_endpoint" {
  description = "AWS IoT Core data endpoint. Set as IOT_ENDPOINT in the device simulator."
  value       = data.aws_iot_endpoint.this.endpoint_address
}

output "dynamodb_table_name" {
  description = "DynamoDB telemetry table name."
  value       = aws_dynamodb_table.telemetry.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB telemetry table ARN."
  value       = aws_dynamodb_table.telemetry.arn
}

output "lambda_function_name" {
  description = "Lambda telemetry processor function name."
  value       = aws_lambda_function.telemetry_processor.function_name
}

output "lambda_function_arn" {
  description = "Lambda telemetry processor function ARN."
  value       = aws_lambda_function.telemetry_processor.arn
}

output "processor_dlq_url" {
  description = "SQS DLQ URL for the Lambda processor. Monitor ApproximateNumberOfMessagesVisible."
  value       = aws_sqs_queue.processor_dlq.url
}

output "cloudwatch_dashboard_url" {
  description = "Direct URL to the operations dashboard in CloudWatch."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.coldchain.dashboard_name}"
}

output "sns_alerts_topic_arn" {
  description = "SNS topic ARN for alarm notifications. Add subscriptions here for PagerDuty, Opsgenie, etc."
  value       = aws_sns_topic.alerts.arn
}

output "registered_things" {
  description = "Map of registered IoT Thing names to their ARNs."
  value       = { for k, v in module.iot_thing : k => v.thing_arn }
}
