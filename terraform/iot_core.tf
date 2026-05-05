# ---------------------------------------------------------------------------
# IoT Core — Thing registry, per-device policies, topic rule
# ---------------------------------------------------------------------------
#
# Design notes:
#
# Thing registration: one Thing per device_id. The Thing name is the
# device identity anchor — it appears in policy conditions, topic prefixes,
# and CloudWatch dimensions. Keeping it stable across certificate rotations
# (a new cert can be attached to the same Thing) is intentional.
#
# Policy scope: each device gets a policy that permits publish only to its
# own topic prefix (dt/coldchain/{device_id}/*) and subscribe/receive on
# its own command topic (cmd/{device_id}/#). No device can publish to
# another device's topic or subscribe to fleet-wide topics. This is the
# minimum viable blast radius for a compromised device.
#
# The "iot:ClientId" policy variable enforces that the MQTT client ID
# matches the certificate's Thing name — a device can't impersonate another
# Thing by using a different client ID.
#
# Topic rule: a single rule routes all cold chain telemetry to the Lambda
# processor. The SQL filter selects the entire payload; schema validation
# happens in Lambda (not the rules engine) so we have a single enforcement
# point and a full DLQ trail on validation failures.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Thing registry
# ---------------------------------------------------------------------------

module "iot_thing" {
  source   = "./modules/iot_thing"
  for_each = toset(var.device_ids)

  thing_name      = each.key
  certificate_arn = lookup(var.certificate_arns, each.key, null)
  topic_prefix    = local.topic_prefix
  name_prefix     = local.name_prefix
  tags            = local.common_tags
}

# ---------------------------------------------------------------------------
# IoT topic rule — telemetry → Lambda
# ---------------------------------------------------------------------------

resource "aws_iot_topic_rule" "telemetry_ingest" {
  name        = replace("${local.name_prefix}_telemetry_ingest", "-", "_")
  description = "Route cold chain telemetry from all devices to the Lambda processor."
  enabled     = true

  # SELECT * routes the full JSON payload. We intentionally avoid filtering
  # fields here — partial field selection in the rules engine means a new
  # telemetry field silently disappears unless the rule is updated.
  # Lambda handles schema validation and field extraction.
  sql         = "SELECT * FROM 'dt/${var.domain}/+/telemetry'"
  sql_version = "2016-03-23"

  lambda {
    function_arn = aws_lambda_function.telemetry_processor.arn
  }

  # Error action: route rules engine errors (not Lambda errors — those go
  # to the Lambda DLQ) to CloudWatch Logs for visibility.
  error_action {
    cloudwatch_logs {
      log_group_name = aws_cloudwatch_log_group.iot_rule_errors.name
      role_arn       = aws_iam_role.iot_rule_logging.arn
    }
  }
}

# Allow IoT Core rules engine to invoke the Lambda processor.
resource "aws_lambda_permission" "iot_invoke" {
  statement_id  = "AllowIoTCoreInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.telemetry_processor.function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.telemetry_ingest.arn
}

# ---------------------------------------------------------------------------
# IAM — IoT rules engine logging role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "iot_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iot_rule_logging" {
  name               = "${local.name_prefix}-iot-rule-logging"
  assume_role_policy = data.aws_iam_policy_document.iot_assume_role.json
}

data "aws_iam_policy_document" "iot_rule_logging" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.iot_rule_errors.arn}:*"]
  }
}

resource "aws_iam_role_policy" "iot_rule_logging" {
  name   = "cloudwatch-logs"
  role   = aws_iam_role.iot_rule_logging.id
  policy = data.aws_iam_policy_document.iot_rule_logging.json
}

# ---------------------------------------------------------------------------
# CloudWatch log group for rules engine errors
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "iot_rule_errors" {
  name              = "/aws/iot/${local.name_prefix}/rule-errors"
  retention_in_days = var.lambda_log_retention_days
}
