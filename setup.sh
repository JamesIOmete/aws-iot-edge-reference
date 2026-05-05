#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — bootstrap the aws-iot-edge-reference repo
#
# Run this once after cloning. Creates virtual environments for the simulator
# and lambda processor, installs dependencies, and validates the Terraform
# working directory.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# Prerequisites:
#   - Python 3.11+
#   - Terraform >= 1.6
#   - AWS CLI configured (aws configure)
# ---------------------------------------------------------------------------

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[setup]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[error]${NC} $*"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

info "Checking prerequisites..."

command -v python3 >/dev/null 2>&1 || error "python3 not found. Install Python 3.11+."
command -v terraform >/dev/null 2>&1 || error "terraform not found. Install Terraform >= 1.6."
command -v aws >/dev/null 2>&1      || warn  "aws CLI not found. You'll need it for certificate provisioning."

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
REQUIRED_MINOR=11
ACTUAL_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)
if [ "$ACTUAL_MINOR" -lt "$REQUIRED_MINOR" ]; then
  error "Python 3.${REQUIRED_MINOR}+ required. Found: Python ${PYTHON_VERSION}"
fi
info "Python ${PYTHON_VERSION} ✓"

TF_VERSION=$(terraform version -json | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])")
info "Terraform ${TF_VERSION} ✓"

# ---------------------------------------------------------------------------
# Simulator venv
# ---------------------------------------------------------------------------

info "Setting up simulator virtual environment..."
cd "$REPO_ROOT/simulator"

python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
deactivate

info "Simulator venv ready: simulator/.venv"

# ---------------------------------------------------------------------------
# Lambda processor venv
# ---------------------------------------------------------------------------

info "Setting up lambda processor virtual environment..."
cd "$REPO_ROOT/lambda"

python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet boto3

# No third-party packages to bundle — Lambda processor uses stdlib only.
# boto3 is provided by the Lambda runtime; installed here for local dev only.
deactivate

info "Lambda processor venv ready: lambda/.venv"

# ---------------------------------------------------------------------------
# Terraform init
# ---------------------------------------------------------------------------

info "Initialising Terraform..."
cd "$REPO_ROOT/terraform"

if [ ! -f terraform.tfvars ]; then
  cp terraform.tfvars.example terraform.tfvars
  warn "terraform.tfvars created from example."
  warn "Edit terraform.tfvars before running terraform apply:"
  warn "  - Set aws_region"
  warn "  - Add certificate_arns (see simulator/certs/README.md)"
  warn "  - Set alert_email (optional)"
fi

terraform init -input=false
terraform validate && info "Terraform config valid ✓"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
info "Setup complete. Next steps:"
echo ""
echo "  1. Provision device certificates:"
echo "       see simulator/certs/README.md"
echo ""
echo "  2. Edit terraform/terraform.tfvars:"
echo "       add certificate ARNs, set aws_region"
echo ""
echo "  3. Deploy infrastructure:"
echo "       cd terraform && terraform plan && terraform apply"
echo ""
echo "  4. Run the simulator:"
echo "       cd simulator"
echo "       source .venv/bin/activate"
echo "       export IOT_ENDPOINT=\$(cd ../terraform && terraform output -raw iot_endpoint)"
echo "       export CERT_PATH=certs/device.pem.crt"
echo "       export KEY_PATH=certs/private.pem.key"
echo "       export CA_PATH=certs/AmazonRootCA1.pem"
echo "       export DEVICE_ID=cold-chain-sim-01"
echo "       python device_simulator.py"
echo ""
echo "  5. Tear down when done:"
echo "       cd terraform && terraform destroy"
echo ""
