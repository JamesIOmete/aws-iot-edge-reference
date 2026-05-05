# ---------------------------------------------------------------------------
# CloudWatch — alarms, metric filters, dashboard, SNS
# ---------------------------------------------------------------------------
#
# Observability design:
#
# Metric filters translate structured Lambda log events into CloudWatch
# custom metrics. The Lambda processor emits JSON log lines with an
# "event_type" field (TEMPERATURE_EXCURSION, BATTERY_LOW, etc.) — filters
# match on that field and increment a counter metric per device_id.
#
# This approach keeps the alarming logic out of the Lambda code itself
# (Lambda doesn't call PutMetricData) and makes the metric history queryable
# in CloudWatch even if the Lambda function is replaced.
#
# Alarms: four conditions that represent real operational events in a cold
# chain deployment. Each has a clear business consequence:
#   - TemperatureExcursion: cargo may be compromised — immediate action
#   - BatteryLow: device will go offline — schedule intervention
#   - DeviceSilence: device is offline — unknown cargo state, worst case
#   - ProcessorErrors: telemetry pipeline degraded — data gaps forming
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# SNS topic — alarm actions
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Metric filters — structured log → CloudWatch metric
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "temperature_excursion" {
  name           = "${local.name_prefix}-temperature-excursion"
  log_group_name = aws_cloudwatch_log_group.lambda_processor.name
  pattern        = "{ $.event_type = \"TEMPERATURE_EXCURSION\" }"

  metric_transformation {
    name          = "TemperatureExcursionCount"
    namespace     = "ColdChain/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "battery_low" {
  name           = "${local.name_prefix}-battery-low"
  log_group_name = aws_cloudwatch_log_group.lambda_processor.name
  pattern        = "{ $.event_type = \"BATTERY_LOW\" }"

  metric_transformation {
    name          = "BatteryLowCount"
    namespace     = "ColdChain/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "telemetry_ingested" {
  name           = "${local.name_prefix}-telemetry-ingested"
  log_group_name = aws_cloudwatch_log_group.lambda_processor.name
  pattern        = "{ $.event_type = \"TELEMETRY_INGESTED\" }"

  metric_transformation {
    name          = "TelemetryIngestedCount"
    namespace     = "ColdChain/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "temperature_excursion" {
  alarm_name          = "${local.name_prefix}-temperature-excursion"
  alarm_description   = "Cold chain temperature excursion detected. Cargo integrity at risk."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = 1

  namespace   = "ColdChain/${var.environment}"
  metric_name = "TemperatureExcursionCount"
  statistic   = "Sum"
  period      = 60 # 1-minute evaluation window

  # 2 consecutive periods = 2 minutes of excursion before alarm fires.
  # A single spike (sensor noise, brief door-open) won't page on-call.
  # Sustained excursion will.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "battery_low" {
  alarm_name          = "${local.name_prefix}-battery-low"
  alarm_description   = "Device battery below ${var.battery_low_threshold_pct}%. Schedule intervention before device goes offline."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 1

  namespace   = "ColdChain/${var.environment}"
  metric_name = "BatteryLowCount"
  statistic   = "Sum"
  period      = 300 # 5-minute window — battery drain is gradual

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "device_silence" {
  alarm_name          = "${local.name_prefix}-device-silence"
  alarm_description   = "No telemetry received for ${var.device_silence_minutes}+ minutes. Device offline or link lost."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 1

  namespace   = "ColdChain/${var.environment}"
  metric_name = "TelemetryIngestedCount"
  statistic   = "Sum"
  period      = var.device_silence_minutes * 60

  # CAUTION: missing data = breaching. If the device stops sending, the metric
  # stops being emitted — we want that to trigger the alarm, not suppress it.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "processor_errors" {
  alarm_name          = "${local.name_prefix}-processor-errors"
  alarm_description   = "Lambda processor errors detected. Telemetry pipeline may have data gaps."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.telemetry_processor.function_name
  }
  statistic = "Sum"
  period    = 60

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${local.name_prefix}-dlq-depth"
  alarm_description   = "Messages in the processor DLQ. Failed telemetry events require investigation."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = aws_sqs_queue.processor_dlq.name
  }
  statistic = "Sum"
  period    = 60

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# CloudWatch dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "coldchain" {
  dashboard_name = "${local.name_prefix}-operations"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Telemetry ingest rate + Lambda errors
      {
        type   = "metric"
        x      = 0
        y = 0
        width = 12
        height = 6
        properties = {
          title  = "Telemetry Ingest Rate"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ColdChain/${var.environment}", "TelemetryIngestedCount",
              { stat = "Sum", period = 60, label = "Messages/min" }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y = 0
        width = 12
        height = 6
        properties = {
          title  = "Lambda Processor Errors"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Errors",
              "FunctionName", aws_lambda_function.telemetry_processor.function_name,
              { stat = "Sum", period = 60, color = "#d13212" }],
            ["AWS/Lambda", "Invocations",
              "FunctionName", aws_lambda_function.telemetry_processor.function_name,
              { stat = "Sum", period = 60, color = "#1f77b4" }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      # Row 2: Excursion events + Battery alerts
      {
        type   = "metric"
        x      = 0
        y = 6
        width = 12
        height = 6
        properties = {
          title  = "Temperature Excursions"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ColdChain/${var.environment}", "TemperatureExcursionCount",
              { stat = "Sum", period = 60, color = "#d13212", label = "Excursions" }]
          ]
          annotations = {
            horizontal = [{ value = 1, label = "Alert threshold", color = "#d13212" }]
          }
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y = 6
        width = 12
        height = 6
        properties = {
          title  = "Battery Low Events"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ColdChain/${var.environment}", "BatteryLowCount",
              { stat = "Sum", period = 300, color = "#ff7f0e", label = "Battery low" }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      # Row 3: DLQ depth + Lambda duration p99
      {
        type   = "metric"
        x      = 0
        y = 12
        width = 12
        height = 6
        properties = {
          title  = "Processor DLQ Depth"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", aws_sqs_queue.processor_dlq.name,
              { stat = "Maximum", period = 60, color = "#d13212", label = "DLQ messages" }]
          ]
          annotations = {
            horizontal = [{ value = 1, label = "Any message = alert", color = "#d13212" }]
          }
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y = 12
        width = 12
        height = 6
        properties = {
          title  = "Lambda Duration p50 / p99 (ms)"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Duration",
              "FunctionName", aws_lambda_function.telemetry_processor.function_name,
              { stat = "p50", period = 60, label = "p50" }],
            ["AWS/Lambda", "Duration",
              "FunctionName", aws_lambda_function.telemetry_processor.function_name,
              { stat = "p99", period = 60, label = "p99", color = "#ff7f0e" }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      # Row 4: Alarm status panel
      {
        type   = "alarm"
        x      = 0
        y = 18
        width = 24
        height = 4
        properties = {
          title = "Alarm Status"
          alarms = [
            aws_cloudwatch_metric_alarm.temperature_excursion.arn,
            aws_cloudwatch_metric_alarm.battery_low.arn,
            aws_cloudwatch_metric_alarm.device_silence.arn,
            aws_cloudwatch_metric_alarm.processor_errors.arn,
            aws_cloudwatch_metric_alarm.dlq_depth.arn,
          ]
        }
      }
    ]
  })
}
