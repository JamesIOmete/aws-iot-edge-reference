# ---------------------------------------------------------------------------
# Lambda — telemetry processor
# ---------------------------------------------------------------------------
#
# Responsible for:
#   1. Validating the inbound telemetry payload (schema, required fields)
#   2. Detecting threshold excursions (temperature, battery) and emitting
#      structured log events that CloudWatch metric filters pick up
#   3. Writing validated records to DynamoDB with a computed TTL
#
# Failure handling:
#   - Lambda retries failed invocations twice (AWS default for async invocations)
#   - After retries are exhausted, the event is sent to the DLQ (SQS)
#   - DLQ depth > 0 triggers a CloudWatch alarm (configured in cloudwatch.tf)
#   - This guarantees no telemetry is silently dropped on processor error
#
# Packaging: the Lambda zip is built from the lambda/processor/ directory.
# A null_resource with a local-exec trigger would rebuild on code changes;
# for a portfolio reference, we use a pre-built zip checked in to the repo.
# A real CI pipeline would build and publish the zip as a pipeline artifact.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# SQS Dead Letter Queue
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "processor_dlq" {
  name                      = "${local.name_prefix}-processor-dlq"
  message_retention_seconds = 1209600 # 14 days — long enough to investigate

  # Encrypt DLQ messages at rest. Telemetry payloads may contain location
  # data (GPS coordinates) that warrants encryption even in a dev environment.
  sqs_managed_sse_enabled = true
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------

data "archive_file" "processor_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/processor"
  output_path = "${path.root}/../lambda/processor.zip"
  excludes    = ["__pycache__", "*.pyc", "*.pyo", "tests/"]
}

resource "aws_lambda_function" "telemetry_processor" {
  function_name = "${local.name_prefix}-telemetry-processor"
  description   = "Validates and persists cold chain telemetry from IoT Core."

  filename         = data.archive_file.processor_zip.output_path
  source_code_hash = data.archive_file.processor_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"

  role    = aws_iam_role.lambda_processor.arn
  timeout = 30 # seconds — DynamoDB writes should complete well within this
  memory_size = 256

  # Reserved concurrency. -1 = unreserved (uses shared account pool).
  # Set a positive integer to cap burst ingestion and protect DynamoDB WCU.
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = {
      DYNAMODB_TABLE              = aws_dynamodb_table.telemetry.name
      TEMP_EXCURSION_THRESHOLD_C  = tostring(var.temp_excursion_threshold_c)
      BATTERY_LOW_THRESHOLD_PCT   = tostring(var.battery_low_threshold_pct)
      TELEMETRY_TTL_DAYS          = tostring(var.telemetry_ttl_days)
      LOG_LEVEL                   = "INFO"
      POWERTOOLS_SERVICE_NAME     = "${local.name_prefix}-processor"
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.processor_dlq.arn
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_cloudwatch_log_group.lambda_processor,
  ]
}

# ---------------------------------------------------------------------------
# CloudWatch log group (created before Lambda to control retention)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "lambda_processor" {
  name              = "/aws/lambda/${local.name_prefix}-telemetry-processor"
  retention_in_days = var.lambda_log_retention_days
}

# ---------------------------------------------------------------------------
# IAM — Lambda execution role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_processor" {
  name               = "${local.name_prefix}-lambda-processor"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Basic execution — CloudWatch Logs only (managed policy).
# The log group ARN is controlled by our explicit log group resource above.
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_processor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Scoped DynamoDB access — write to the telemetry table only.
data "aws_iam_policy_document" "lambda_dynamodb" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",   # needed for idempotency checks
    ]
    resources = [
      aws_dynamodb_table.telemetry.arn,
    ]
  }
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name   = "dynamodb-telemetry-write"
  role   = aws_iam_role.lambda_processor.id
  policy = data.aws_iam_policy_document.lambda_dynamodb.json
}

# DLQ send permission — Lambda needs this to write to the SQS DLQ on failure.
data "aws_iam_policy_document" "lambda_dlq" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.processor_dlq.arn]
  }
}

resource "aws_iam_role_policy" "lambda_dlq" {
  name   = "sqs-dlq-send"
  role   = aws_iam_role.lambda_processor.id
  policy = data.aws_iam_policy_document.lambda_dlq.json
}
