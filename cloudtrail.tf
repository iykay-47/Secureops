# S3 bucket for CloudTrail raw event storage.
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project_name}-secureops-cloudtrail" #replace with var.prefix and car.account.id when creating the modules
  force_destroy = true                                       # Acceptable for dev — trail logs are also in CloudWatch

  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "cloudwatch-alarms"
    Purpose   = "cloudtrail-storage"
  })
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudTrail-specific bucket policy.

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = ["s3:GetBucketAcl", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "CloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" #KMS can be used for this
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration {
    status = "Enabled"
  }
}
# CloudWatch Log Group — CloudTrail streams events here in near real-time.

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "${var.project_name}-cloudtrail-log-group" #Make in Var for module
  retention_in_days = var.retention_days
  #   kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null # make a new kms key with condition set if var_kms_key = "" create_kms(1) : 0

  tags = merge(var.tags, { Purpose = "cloudtrail-iam-monitoring" })
}

# CloudTrail assume Role

resource "aws_iam_role" "cloudtrail_cw" {
  name        = "${var.project_name}-cloudtrail-cw-role"
  description = "Allows CloudTrail to deliver events to CloudWatch Logs."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudTrailAssume"
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "cloudwatch-alarms"
  })
}

# Policy attached to the CloudTrail role — scoped to the specific log group.

resource "aws_iam_role_policy" "cloudtrail_cw" {
  name = "${var.project_name}-cloudtrail-cw-policy"
  role = aws_iam_role.cloudtrail_cw.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCWLogsDelivery"
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# CloudTrail — the trail itself.

resource "aws_cloudtrail" "secureops" {
  name                          = "${var.project_name}-secureops-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true # Captures IAM, STS, CloudFront (global services)
  is_multi_region_trail         = true # Captures all regions — IAM calls go to us-east-1
  enable_log_file_validation    = true # Detects tampering with trail log files

  # Stream to CloudWatch Logs for near-real-time metric filtering

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cw.arn

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_iam_role_policy.cloudtrail_cw,
  ]

  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "cloudwatch-alarms"
  })
}

# Metric_Filter pattern breakdown:
resource "aws_cloudwatch_log_metric_filter" "iam_policy_change" {
  name           = "${var.project_name}-iam-policy-change"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  pattern = "{($.eventSource = \"iam.amazonaws.com\") && (($.eventName = \"DeleteRolePolicy\") || ($.eventName = \"AttachRolePolicy\") || ($.eventName = \"PutRolePolicy\") || ($.eventName = \"CreatePolicy\") || ($.eventName = \"DetachRolePolicy\") || ($.eventName = \"UpdateAssumeRolePolicy\")) && ($.errorCode NOT EXISTS)}"

  metric_transformation {
    name          = "IAMPolicyChangeCount"
    namespace     = "SecureOps/Security"
    value         = "1"
    default_value = 0 # Emit 0 when no match — keeps alarm in OK not INSUFFICIENT_DATA
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_policy_change" {
  alarm_name          = "${var.project_name}-iam-policy-change-detected"
  alarm_description   = "A successful IAM policy modification was detected via CloudTrail. Review CloudTrail logs immediately to verify this was authorized."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "IAMPolicyChangeCount"
  namespace           = "SecureOps/Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, { AlarmCategory = "security" })
}