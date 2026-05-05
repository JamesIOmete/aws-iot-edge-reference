# ---------------------------------------------------------------------------
# DynamoDB — telemetry storage
# ---------------------------------------------------------------------------
#
# Key design:
#
# Partition key: device_id  — all reads start with "give me data for device X"
# Sort key:      timestamp  — ISO 8601 string; sorts lexicographically, which
#                             is correct for time-ordered data.
#
# Primary query pattern: Query(pk=device_id, sk BETWEEN t_start AND t_end)
# No scan required. No secondary index needed for the hot path.
#
# GSI (fleet_id-timestamp-index): supports cross-device queries when devices
# are grouped by fleet (e.g. "all readings from Fleet A in the last hour").
# fleet_id is written by the Lambda processor from the topic structure.
# This is a sparse index — devices without a fleet_id don't appear in it.
#
# TTL (expires_at): epoch timestamp written by Lambda as
# ingestion_time + telemetry_ttl_days * 86400. DynamoDB deletes expired
# items asynchronously — they're queryable until actually deleted, so
# application code must filter on timestamp if strict TTL enforcement matters.
#
# Billing mode: PAY_PER_REQUEST. Cold chain telemetry has bursty write
# patterns (convoy of trucks arriving simultaneously). On-demand avoids
# capacity planning guesswork for a reference deployment. Switch to
# PROVISIONED with auto-scaling for cost optimization at sustained high
# throughput (>10k WCU sustained).
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "telemetry" {
  name         = "${local.name_prefix}-telemetry"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "device_id"
  range_key = "timestamp"

  attribute {
    name = "device_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "fleet_id"
    type = "S"
  }

  # TTL — epoch seconds. Lambda writes this field; DynamoDB handles deletion.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # GSI: query by fleet across all devices
  global_secondary_index {
    name            = "fleet_id-timestamp-index"
    hash_key        = "fleet_id"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  # Point-in-time recovery — enabled even for dev; the cost is negligible
  # and the operational reflex of having it on by default is correct.
  point_in_time_recovery {
    enabled = true
  }

  # Server-side encryption with AWS-managed key (default).
  # For HIPAA/PCI workloads, switch to a customer-managed KMS key.
  server_side_encryption {
    enabled = true
  }
}
