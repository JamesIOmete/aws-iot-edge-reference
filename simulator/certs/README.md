# Certificate provisioning

This directory holds X.509 device certificates. **It is `.gitignored` — never commit private key material.**

Certificates are pre-provisioned before running `terraform apply`. Terraform manages the association between a certificate ARN, an IoT Thing, and a policy — not the certificate lifecycle itself. This keeps private key material out of Terraform state.

---

## Provisioning sequence (AWS CLI)

Run once per device. Replace `DEVICE_ID` with your actual device ID (e.g. `cold-chain-sim-01`).

```bash
DEVICE_ID="cold-chain-sim-01"
REGION="us-east-1"
```

### 1. Create and register a certificate

```bash
aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile certs/device.pem.crt \
  --public-key-outfile certs/public.pem.key \
  --private-key-outfile certs/private.pem.key \
  --region $REGION
```

Note the `certificateArn` in the output — you'll need it for `terraform.tfvars`.

```bash
# Extract the ARN programmatically
CERT_ARN=$(aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile certs/device.pem.crt \
  --public-key-outfile certs/public.pem.key \
  --private-key-outfile certs/private.pem.key \
  --region $REGION \
  --query 'certificateArn' \
  --output text)

echo "Certificate ARN: $CERT_ARN"
```

### 2. Download the Amazon Root CA

```bash
curl -o certs/AmazonRootCA1.pem \
  https://www.amazontrust.com/repository/AmazonRootCA1.pem
```

### 3. Update terraform.tfvars

```hcl
certificate_arns = {
  "cold-chain-sim-01" = "arn:aws:iot:us-east-1:ACCOUNT_ID:cert/CERTIFICATE_ID"
}
```

### 4. Run terraform apply

The `iot_thing` module attaches the certificate to the Thing and policy. After `apply`, the simulator can connect.

---

## Files in this directory after provisioning

| File | Description |
|------|-------------|
| `device.pem.crt` | Device certificate (public) |
| `private.pem.key` | Device private key — treat as a secret |
| `public.pem.key` | Device public key — not used by the simulator |
| `AmazonRootCA1.pem` | Amazon Root CA — authenticates the IoT Core broker |

---

## Certificate revocation

To revoke a device (lost or compromised):

```bash
# 1. Get the certificate ID from the ARN or console
CERT_ID="abc123..."

# 2. Detach from policy and Thing (or let Terraform handle this on destroy)
aws iot update-certificate --certificate-id $CERT_ID --new-status REVOKED --region $REGION

# 3. The device will be refused on next connect attempt
```

This is the operational advantage of X.509 over API keys: revocation is per-device and immediate, with no impact on the rest of the fleet.

---

## Cleanup

```bash
# Delete local cert material
rm certs/device.pem.crt certs/private.pem.key certs/public.pem.key

# Deactivate and delete the certificate in AWS (after terraform destroy)
aws iot update-certificate --certificate-id $CERT_ID --new-status INACTIVE --region $REGION
aws iot delete-certificate --certificate-id $CERT_ID --region $REGION
```
