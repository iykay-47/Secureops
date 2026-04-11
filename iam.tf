# Ec2 IAM role for s3 and Cloudwatch
data "aws_iam_policy_document" "test-data-ec2-profile" {
  statement {
    sid    = "ReadWriteS3Bucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [aws_s3_bucket.test_store.arn, "${aws_s3_bucket.test_store.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["true"]
    }
  }

  statement {
    sid       = "S3List"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.test_store.arn]
  }

  statement {
    sid    = "CWLogsWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:PutRetentionPolicy"
    ]
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}:*", "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}"]
  }

  statement {
    sid    = "CloudWatchMetricsPush"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"] # PutMetricData does not support resource-level restrictions (AWS limitation)

    #     # Scope to a specific custom namespace
    #     condition {
    #       test     = "StringEquals"
    #       variable = "cloudwatch:namespace"
    #       values   = [var.cloudwatch_namespace] #Replace with specific namespace e.g "AWS/EC2"
    #     }

  }

# SECURITY! - Block any attempt to modify IAM from the EC2 instance.
  statement {
    sid    = "DenyIAMModification"
    effect = "Deny"
    actions = [
      "iam:*",
    ]
    resources = ["*"]
  }

# Block access to any other S3 bucket not in the approved list.
  statement {
    sid           = "DenyNonApprovedS3Buckets"
    effect        = "Deny"
    actions       = ["s3:*"]
    not_resources = [aws_s3_bucket.test_store.arn, "${aws_s3_bucket.test_store.arn}/*"]
  }

  depends_on = [aws_s3_bucket.test_store]
}

# Cloudwatch Read-Only role
data "aws_iam_policy_document" "CW_monitoring" {
  statement {
    sid    = "CWReadOnly"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "LogsReadOnly"
    effect = "Allow"
    actions = [
      "logs:GetLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStream",
      "logs:FilterLogEvents"
    ]
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}:*", "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}"]
  }

#Ensure ReadOnly from cloudwatch
  statement {
    sid    = "DenyCWWritePermisions"
    effect = "Deny"
    actions = [
      "cloudwatch:Put*",
      "cloudwatch:Delete*",
      "cloudwatch:Set*",
      "logs:Create*",
      "logs:Put*",
      "logs:Delete*"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ec2-role" {
  name        = "Ec2-s3-role"
  path        = var.policy_path
  description = "Ec2-S3 data transfer policy"
  policy      = data.aws_iam_policy_document.test-data-ec2-profile.json

  tags = merge(var.tags, {
    Module     = "iam-policy"
    PolicyType = "EC2-policy"
  })
}

resource "aws_iam_policy" "cw_policy" {
  name        = "CWatch_Read_Only"
  path        = var.policy_path
  description = "Cloud Watch ReadOnly Policy"
  policy      = data.aws_iam_policy_document.CW_monitoring.json

  tags = merge(var.tags, {
    Module     = "iam-policy"
    PolicyType = "CW-Policy"
  })
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "cw_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ec2_instance_profile" {
  name               = "${var.project_name}-ec2-assume-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role" "cw_assume_role" {
  name               = "${var.project_name}-cw-assume-role"
  assume_role_policy = data.aws_iam_policy_document.cw_assume_role.json
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance_profile.name
}

resource "aws_iam_role_policy_attachment" "ec2_assume_role" {
  role       = aws_iam_role.ec2_instance_profile.name
  policy_arn = aws_iam_policy.ec2-role.arn

  depends_on = [aws_iam_role.ec2_instance_profile, aws_iam_policy.ec2-role]
}

resource "aws_iam_role_policy_attachment" "cw_assume_role" {
  role       = aws_iam_role.cw_assume_role.name
  policy_arn = aws_iam_policy.cw_policy.arn

  depends_on = [aws_iam_role.cw_assume_role, aws_iam_policy.cw_policy]
}