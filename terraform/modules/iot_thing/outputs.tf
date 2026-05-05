output "thing_name" {
  description = "Registered IoT Thing name."
  value       = aws_iot_thing.this.name
}

output "thing_arn" {
  description = "ARN of the registered IoT Thing."
  value       = aws_iot_thing.this.arn
}

output "policy_name" {
  description = "Name of the per-device IoT policy."
  value       = aws_iot_policy.device.name
}

output "policy_arn" {
  description = "ARN of the per-device IoT policy."
  value       = aws_iot_policy.device.arn
}
