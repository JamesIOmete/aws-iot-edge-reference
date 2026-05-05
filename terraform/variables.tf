variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project identifier. Used as the base of all resource names."
  type        = string
  default     = "iot-coldchain"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Appended to resource names."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "domain" {
  description = "IoT domain label. Used in MQTT topic namespace (dt/{domain}/{device_id}/telemetry)."
  type        = string
  default     = "coldchain"
}

# ---------------------------------------------------------------------------
# Device / fleet
# ---------------------------------------------------------------------------

variable "device_ids" {
  description = <<-EOT
    List of device IDs to register as IoT Things. Each device gets its own
    Thing in the registry and is expected to have a pre-provisioned X.509
    certificate. See simulator/certs/README.md for the provisioning sequence.
  EOT
  type        = list(string)
  default     = ["cold-chain-sim-01"]
}

variable "certificate_arns" {
  description = <<-EOT
    Map of device_id → IoT certificate ARN. Certificates must be pre-provisioned
    in AWS IoT Core before running terraform apply. The simulator/certs/README.md
    walks through the AWS CLI commands to create and register certificates.

    Example:
      certificate_arns = {
        "cold-chain-sim-01" = "arn:aws:iot:us-east-1:123456789012:cert/abc123..."
      }
  EOT
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Telemetry thresholds — used in Lambda environment and CloudWatch alarms
# ---------------------------------------------------------------------------

variable "temp_excursion_threshold_c" {
  description = <<-EOT
    Temperature threshold in Celsius above which a cold chain excursion alarm
    fires. Standard refrigerated cargo range is 2–8°C; 8°C is the typical
    upper limit for pharma and food applications.
  EOT
  type        = number
  default     = 8.0
}

variable "battery_low_threshold_pct" {
  description = "Battery percentage below which the BatteryLow alarm fires."
  type        = number
  default     = 15
}

variable "device_silence_minutes" {
  description = <<-EOT
    Minutes of silence from a device before the DeviceSilence alarm fires.
    A device publishing every 10 seconds that goes quiet for 5 minutes has
    either lost its link or crashed. Tune down for tighter SLAs.
  EOT
  type        = number
  default     = 5
}

variable "telemetry_ttl_days" {
  description = <<-EOT
    DynamoDB TTL for telemetry records, in days. Records older than this are
    automatically deleted. 90 days covers most regulatory audit windows for
    food and pharma cold chain; adjust to your compliance requirement.
  EOT
  type        = number
  default     = 90
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------

variable "alert_email" {
  description = <<-EOT
    Email address for CloudWatch alarm notifications via SNS. Leave empty to
    skip email subscription (alarms will still fire; you just won't get email).
    Wire in a PagerDuty or Opsgenie endpoint here for production use.
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------

variable "lambda_log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda processor log group, in days."
  type        = number
  default     = 30
}

variable "lambda_reserved_concurrency" {
  description = <<-EOT
    Reserved concurrency for the telemetry processor Lambda. -1 means unreserved
    (uses account-level concurrency pool). Set a positive integer to cap burst
    ingestion and protect downstream DynamoDB write capacity.
  EOT
  type        = number
  default     = -1
}
