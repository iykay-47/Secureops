resource "aws_s3_bucket" "test_store" {
  bucket_prefix = "my-ec2-s3-test"

  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "test_store" {
  bucket = aws_s3_bucket.test_store.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "test_store" {
  bucket = aws_s3_bucket.test_store.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#Encrypt Data at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "test_store" {
  bucket = aws_s3_bucket.test_store.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" #KMS can be used for this
    }
    bucket_key_enabled = true
  }
}
# Make 4xx and 5xx available to cloudwatch
resource "aws_s3_bucket_metric" "test-store" {
  bucket = aws_s3_bucket.test_store.id
  name = "EntireBucket"
}

resource "aws_s3_bucket_policy" "test_store" {
  bucket = aws_s3_bucket.test_store.id
  policy = data.aws_iam_policy_document.test_store_bucket_policy.json

  depends_on = [
    aws_s3_bucket.test_store,
    aws_s3_bucket_public_access_block.test_store,
    data.aws_iam_policy_document.test_store_bucket_policy
  ]
}

data "aws_iam_policy_document" "test_store_bucket_policy" {
  # Deny any request not using TLS/HTTPS
  statement {
    sid    = "DenyNonSecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
    resources = [aws_s3_bucket.test_store.arn, "${aws_s3_bucket.test_store.arn}/*"]
  }

  #Deny any request from anyone other than the ec2 resource specified
  statement {
    sid    = "DenyNonEc2Access"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.test_store.arn, "${aws_s3_bucket.test_store.arn}/*"]
    condition {
      test = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values = [
        aws_iam_role.ec2_instance_profile.arn,
        data.aws_caller_identity.current.arn
      ]
    }
  }

  #Deny Non-Encrypted data sent to s3bucket
  statement {
    sid    = "DenyUnencryptedObjects"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = [aws_s3_bucket.test_store.arn, "${aws_s3_bucket.test_store.arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["AES256"]
    }
  }

  depends_on = [aws_s3_bucket.test_store, aws_instance.data_pipeline]
}