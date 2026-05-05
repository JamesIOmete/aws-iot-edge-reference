# ---------------------------------------------------------------------------
# Module: iot_thing
#
# Registers one IoT Thing and attaches:
#   - a per-device least-privilege publish/subscribe policy
#   - the pre-provisioned X.509 certificate
#
# Designed to be called with for_each from the root module, once per device.
# Keeping this as a module signals fleet-scale thinking: you provision Things
# in a loop, not by hand.
# ---------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Thing
# ---------------------------------------------------------------------------

resource "aws_iot_thing" "this" {
  name = var.thing_name

  # Thing attributes are queryable via ListThings — useful for fleet
  # management tooling (e.g. platformctl) that needs to filter devices
  # by firmware version or hardware revision without a separate registry.
  attributes = {
    device_type = "cold-chain-sensor"
    managed_by  = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Per-device IoT policy
# ---------------------------------------------------------------------------
#
# Policy design:
#
# Connect: the device may only connect with a client ID that matches its
# Thing name. The ${iot:ClientId} variable is resolved by IoT Core at
# connect time — a device cannot use a different client ID to bypass
# topic-level restrictions.
#
# Publish: scoped to dt/{domain}/{thing_name}/* only. The device cannot
# publish to any other device's topic or to the command namespace.
#
# Subscribe/Receive: scoped to the device's own command topic
# (cmd/{thing_name}/#). Telemetry is publish-only — the device does not
# subscribe to its own telemetry topic.
#
# GetThingShadow/UpdateThingShadow: reserved for the extension pattern
# (OTA, bi-directional commands). Included here so the policy doesn't need
# to be replaced when those patterns are added.

data "aws_iam_policy_document" "device_policy" {
  # Connect — enforce client ID == Thing name
  statement {
    effect    = "Allow"
    actions   = ["iot:Connect"]
    resources = ["arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:client/${var.thing_name}"]

    condition {
      test     = "StringEquals"
      variable = "iot:ClientId"
      values   = [var.thing_name]
    }
  }

  # Publish — telemetry topic only
  statement {
    effect  = "Allow"
    actions = ["iot:Publish"]
    resources = [
      "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/${var.topic_prefix}/${var.thing_name}/*"
    ]
  }

  # Subscribe + Receive — command topic (extension pattern)
  statement {
    effect  = "Allow"
    actions = ["iot:Subscribe", "iot:Receive"]
    resources = [
      "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topicfilter/cmd/${var.thing_name}/*"
    ]
  }

  # Device Shadow — read and write own shadow only (extension pattern)
  statement {
    effect  = "Allow"
    actions = ["iot:GetThingShadow", "iot:UpdateThingShadow"]
    resources = [
      "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:thing/${var.thing_name}"
    ]
  }
}

resource "aws_iot_policy" "device" {
  name   = "${var.name_prefix}-device-${var.thing_name}"
  policy = data.aws_iam_policy_document.device_policy.json
}

# ---------------------------------------------------------------------------
# Certificate attachment
# ---------------------------------------------------------------------------
#
# Certificates are pre-provisioned (created outside Terraform, registered in
# IoT Core, and their ARNs passed in via terraform.tfvars). This reflects a
# real provisioning workflow: certificates are generated at the manufacturing
# line or provisioning station and registered before the device ships.
#
# Terraform manages the association between cert ↔ policy ↔ Thing — not the
# certificate lifecycle itself. This keeps private key material out of
# Terraform state entirely.

resource "aws_iot_policy_attachment" "device" {
  count  = var.certificate_arn != null ? 1 : 0
  policy = aws_iot_policy.device.name
  target = var.certificate_arn
}

resource "aws_iot_thing_principal_attachment" "device" {
  count     = var.certificate_arn != null ? 1 : 0
  thing     = aws_iot_thing.this.name
  principal = var.certificate_arn
}

# ---------------------------------------------------------------------------
# Data sources — used in policy ARN construction
# ---------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
