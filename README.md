# SecureOps — Secure Data Pipeline

Terraform project that provisions a hardened AWS data pipeline. An EC2 instance generates synthetic access logs every 5 minutes, uploads them to a locked-down S3 bucket, and streams metrics and logs to CloudWatch. CloudTrail audits all API activity, and three CloudWatch alarms fire SNS email alerts on CPU spikes, S3 access errors, and IAM policy changes.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  EC2  t2.micro · Amazon Linux 2023                              │
│  IAM instance profile · SSM Session Manager                     │
│                                                                 │
│  systemd timers (every 5 min)                                   │
│    secureops-generate  →  20 log lines  →  S3 input/            │
│    secureops-stress    →  CPU load (alarm testing only)         │
│                                                                 │
│  CloudWatch Agent  →  CPU / mem / disk metrics                  │
│                    →  /var/log/secureops/pipeline.log           │
└────────────┬────────────────────────┬───────────────────────────┘
             │                        │
             ▼                        ▼
  ┌──────────────────┐     ┌─────────────────────────┐
  │  S3 pipeline     │     │  CloudWatch Logs         │
  │  AES256 · HTTPS  │     │  /<project>/<env>/       │
  │  EC2-only policy │     │  pipeline                │
  │  Versioned       │     └─────────────────────────┘
  └──────────────────┘

  CloudTrail (multi-region · log validation)
    → S3 cloudtrail bucket  (encrypted · versioned)
    → CloudWatch Log Group  → metric filter
                                    │
                            IAM change alarm ─┐
                            CPU spike alarm   ├──► SNS → email
                            S3 4xx alarm    ──┘
```

---

## Prerequisites

- Terraform `>= 1.6.0`
- AWS CLI configured (`aws configure` or environment variables)
- IAM permissions to create EC2, S3, IAM, CloudWatch, CloudTrail, and SNS resources
- An EC2 key pair in the target region (only needed for SSH — SSM works without one)

---

## Quick Start

```bash
git clone https://github.com/iykay-47/Secureops.git
cd secureops
```

# 2. Copy and edit the variables file
```bash
cp terraform.tfvars.example terraform.tfvars
```
Miniumum edits
```hcl
alert_emails = ["you@example.com"]
ssh_cidr     = "203.0.113.10/32"   # your IP, or remove the SG rule and use SSM only
key_name     = "your-key-pair-name"
```

Then apply:

```bash
terraform init
terraform plan
terraform apply
```

**After apply:** check your inbox and confirm the SNS subscription — alerts won't deliver until you do.

---

## Variables

| Variable | Default | Description |
|---|---|---|
| `region` | `us-east-2` | AWS region |
| `environment` | `dev` | Environment label — used in resource names and log group path |
| `project_name` | `secure-data-pipeline` | Prefix for all resource names |
| `tags` | `{Environment, ManagedBy, Project}` | Tags applied to all resources |
| `ami_id` | `null` | Override AMI. `null` uses the latest Amazon Linux 2023 x86_64 |
| `key_name` | `test-deployer-key` | EC2 key pair for SSH |
| `ssh_cidr` | `0.0.0.0/0` | CIDR for SSH ingress. Set this to your IP |
| `alert_emails` | `["..."]` | Email addresses for SNS alarm notifications |
| `cpu_threshold_percent` | `65` | EC2 CPU % threshold for the spike alarm |
| `s3_4xx_threshold` | `5` | S3 4xx error count (in 5 min) before alarming |
| `retention_days` | `7` | CloudWatch log group retention. Increase for compliance environments |
| `kms_key_arn` | `null` | Optional KMS key for log group and SNS encryption |
| `policy_path` | `/` | IAM policy path |

> IAM resources are tagged explicitly on each resource — they do not inherit provider-level `default_tags` due to an AWS API limitation.

---

## File Structure

```
├── main.tf           # Provider config, Terraform version constraints
├── variable.tf       # All input variables
├── ec2.tf            # AMI data source, VPC/subnets, security group, EC2 instance
├── iam.tf            # EC2 instance profile, CloudWatch read-only role, policies
├── s3.tf             # Pipeline bucket — encryption, versioning, policy, request metrics
├── cloudtrail.tf     # Trail, S3 bucket, CW log group, IAM role, metric filter + alarm
├── cloudwatch.tf     # SNS topic, CPU alarm, S3 4xx alarm, dashboard
├── output.tf         # Public IP, profile ARN, role ARN, caller ARN
└── user-data.tftpl   # EC2 bootstrap — CW agent, log generator, systemd timers
```

---

## Security Controls

### S3 pipeline bucket

| Control | Implementation |
|---|---|
| Encryption at rest | AES256 SSE-S3, `bucket_key_enabled = true` |
| Encryption in transit | Bucket policy `Deny` where `aws:SecureTransport = false` |
| Unencrypted uploads | Bucket policy `Deny s3:PutObject` without `x-amz-server-side-encryption: AES256` |
| Access scope | Bucket policy restricts to the EC2 IAM role and the Terraform caller identity |
| Public access | All four `aws_s3_bucket_public_access_block` settings enabled |
| Versioning | Enabled |
| Request metrics | `aws_s3_bucket_metric "EntireBucket"` — required for the 4xx CloudWatch alarm |

### EC2 IAM instance profile

| Statement | Effect | Scope |
|---|---|---|
| `s3:GetObject / PutObject / DeleteObject` | Allow | Pipeline bucket only, `aws:SecureTransport = true` condition |
| `s3:ListBucket` | Allow | Pipeline bucket only |
| `logs:Create* / PutLogEvents / Describe*` | Allow | Scoped log group ARN |
| `cloudwatch:PutMetricData` | Allow | `*` — AWS does not support resource-level restrictions here |
| `iam:*` | **Deny** | `*` — blocks privilege escalation from the instance |
| `s3:*` on non-approved buckets | **Deny** | `NotResources` — prevents lateral movement to other buckets |
| SSM Session Manager | Allow | Via `AmazonSSMManagedInstanceCore` managed policy |

### CloudTrail

| Setting | Detail |
|---|---|
| Multi-region | Captures IAM/STS calls that route to `us-east-1` regardless of deploy region |
| Global service events | Enabled |
| Log file validation | Enabled — detects tampering with delivered log files |
| Storage | Dedicated encrypted, versioned, public-access-blocked S3 bucket |
| Real-time delivery | CloudWatch Logs via a scoped IAM delivery role |

---

## Alarms

All three alarms route to the same SNS topic and appear in the CloudWatch dashboard.

| Alarm | Metric | Condition | Fires when |
|---|---|---|---|
| CPU spike | `AWS/EC2 CPUUtilization` | `> 65%` for 2 × 5-min periods | Runaway process or cryptomining |
| S3 4xx errors | `AWS/S3 4xxErrors` (EntireBucket) | `≥ 5` in 5 min | Credential probing or access misconfiguration |
| IAM policy change | `SecureOps/Security IAMPolicyChangeCount` | `≥ 1` in 5 min | Any successful IAM policy modification |

The IAM alarm is driven by a CloudTrail metric filter watching for `AttachRolePolicy`, `DetachRolePolicy`, `PutRolePolicy`, `DeleteRolePolicy`, `CreatePolicy`, and `UpdateAssumeRolePolicy` events with no error code.

---

## EC2 Bootstrap

`user-data.tftpl` runs once on first boot. Terraform renders it at plan time via `templatefile()`, injecting the bucket name, region, environment, and log group path as literal values before the script runs.

1. Installs `amazon-cloudwatch-agent` and `stress` via `dnf`
2. Writes the CloudWatch Agent config — collects CPU, memory, and disk to `SecureOps/EC2`, and tails `pipeline.log` into the project log group
3. Writes `/opt/secureops/generate.sh` — generates 20 synthetic Apache-format log lines per run and uploads them to `s3://<bucket>/input/<date>/access-<time>.log` with `--sse AES256`
4. Configures daily log rotation with `copytruncate` (preserves the agent's open file handle)
5. Installs two systemd timers on a 5-minute schedule:
   - `secureops-generate` — log generation and S3 upload
   - `secureops-stress` — `stress --cpu 2 --timeout 255` to validate the CPU alarm

> **Remove `secureops-stress.timer` before any production use.** It exists only to trigger the CPU alarm during testing.

---

## Verifying the Deployment

**Connect to the instance:**
```bash
# Via SSM (no key or open port required — preferred)
aws ssm start-session --target <instance-id> --region us-east-2

# Via SSH
ssh -i ~/.ssh/your-key.pem ec2-user@<public-ip>
```

**Check bootstrap completed:**
```bash
cat /var/log/user-data.log | grep "bootstrap complete"
```

**Check timers are running:**
```bash
systemctl list-timers --all | grep secureops
```

**Check files are reaching S3:**
```bash
aws s3 ls s3://<bucket>/input/ --recursive --region us-east-2
```

**Check logs are reaching CloudWatch:**
```bash
aws logs tail /<project-name>/dev/pipeline --follow --region us-east-2
```

**Check CloudWatch Agent status:**
```bash
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
```

---

## Outputs

| Output | Value |
|---|---|
| `ip_address` | Public IP of the EC2 instance |
| `instance_profile_arn` | ARN of the EC2 instance profile |
| `ec2_assume_role_arn` | ARN of the EC2 IAM policy |
| `assumed_arn` | ARN of the Terraform caller identity |

---

## Production Hardening Checklist

- [ ] Set `ssh_cidr` to a specific IP, or remove the SSH ingress rule and use SSM exclusively
- [ ] Set `retention_days` to `90` or higher (CIS benchmark recommends 365 for audit logs)
- [ ] Set `kms_key_arn` to enable KMS encryption on the CloudWatch log group and SNS topic
- [ ] Remove `secureops-stress.timer` from `user-data.tftpl`
- [ ] Remove `force_destroy = true` from both S3 buckets
- [ ] Replace the default VPC with a dedicated VPC and private subnets
- [ ] Change `t2.micro` to `t3.micro` or larger (same Free Tier cost, Nitro hypervisor)
- [ ] Add the AWS account ID to the CloudTrail bucket name to guarantee global uniqueness

---

## Teardown

```bash
terraform destroy
```

Both S3 buckets have `force_destroy = true` so Terraform will empty and delete them automatically.

---

## Testing S3 Uploads

`test-s3.sh` makes 5 upload attempts to a named bucket and prints HTTP status codes. Update the bucket name and region at the top of the script before running:

```bash
chmod +x test-s3.sh
./test-s3.sh
```
