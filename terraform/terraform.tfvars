# Copy this file to terraform.tfvars and fill in your values.
# terraform.tfvars is .gitignored — never commit real certificate ARNs
# or account-specific values to source control.

aws_region  = "us-west-2"
project     = "iot-coldchain"
environment = "dev"
domain      = "coldchain"

# Device IDs to register as IoT Things.
# Add one entry per physical or simulated device.
device_ids = [
  "cold-chain-sim-01",
]

# Map each device_id to its pre-provisioned IoT certificate ARN.
# Run the provisioning sequence in simulator/certs/README.md first,
# then paste the ARNs here.

certificate_arns = {
  "cold-chain-sim-01" = "arn:aws:iot:us-west-2:389149116969:cert/f40f734b394b24353bbcfcc3f90b440e88c93c971402b5d7ccd80dc38cd4a4fb"
}

# Telemetry thresholds
temp_excursion_threshold_c = 8.0
battery_low_threshold_pct  = 15
device_silence_minutes     = 5
telemetry_ttl_days         = 90

# Alerting — set to your email or leave empty to skip SNS email subscription
alert_email = "jward448@gmail.com"

# Lambda
lambda_log_retention_days   = 30
lambda_reserved_concurrency = -1  # -1 = unreserved
