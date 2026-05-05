terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — uncomment and configure for real team use.
  # For a solo evaluation deployment, local state is fine.
  #
  # backend "s3" {
  #   bucket         = "your-tf-state-bucket"
  #   key            = "aws-iot-edge-reference/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "your-tf-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  # Naming prefix applied to every resource — keeps the deployment
  # identifiable and makes teardown auditable (filter by prefix in console).
  name_prefix = "${var.project}-${var.environment}"

  # Topic namespace. Pattern: dt/{domain}/{device_id}/telemetry
  # The "dt/" prefix is a deliberate convention — it separates device
  # telemetry from command traffic (cmd/) and shadow traffic ($aws/things/)
  # at the policy and rules-engine level without needing per-resource ACLs.
  topic_prefix = "dt/${var.domain}"

  # Tags applied to every resource via provider default_tags.
  # Keeps cost allocation and resource discovery consistent.
  common_tags = {
    Project     = var.project
    Environment = var.environment
    Domain      = var.domain
    ManagedBy   = "terraform"
    Repo        = "aws-iot-edge-reference"
  }
}
