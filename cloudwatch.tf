# SNS Topic — receive alarm notifications
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-secureops-alerts"
  #   kms_master_key_id = "alias/aws/sns"

  tags = merge(var.tags, {
    Module = "cloudwatch-alarms"
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = length(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_emails[count.index]
}

# ALARM 1: EC2 CPU Spike

resource "aws_cloudwatch_metric_alarm" "ec2_cpu_spike" {
  alarm_name          = "${var.project_name}-ec2-cpu-spike"
  alarm_description   = "EC2 CPU exceeded ${var.cpu_threshold_percent}% for 10 consecutive minutes. Investigate for runaway process or cryptomining activity."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_threshold_percent
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.data_pipeline.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, { AlarmCategory = "operational" })

  depends_on = [aws_instance.data_pipeline, aws_sns_topic.alerts]
}

# ALARM 2: S3 Unauthorized Access (4xx Errors)

resource "aws_cloudwatch_metric_alarm" "s3_unauthorized_access" {
  alarm_name          = "${var.project_name}-s3-unauthorized-access"
  alarm_description   = "S3 bucket ${aws_s3_bucket.test_store.id} returned >=${var.s3_4xx_threshold} 4xx errors in 5 minutes. Possible credential probing or access control misconfiguration."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "4xxErrors"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Sum"
  threshold           = var.s3_4xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    BucketName = aws_s3_bucket.test_store.id #Insert bucket id and dependency
    FilterId   = "EntireBucket"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, { AlarmCategory = "access" })

  depends_on = [aws_s3_bucket.test_store, aws_sns_topic.alerts, aws_s3_bucket_metric.test-store]
}

# CloudWatch Dashboard

resource "aws_cloudwatch_dashboard" "secureops" {
  dashboard_name = "${var.project_name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 7
        height = 3
        width  = 3
        properties = {
          markdown = "Test-Test Widget"
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 4
        properties = {
          title = "SecureOps — Active Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.ec2_cpu_spike.arn,
            aws_cloudwatch_metric_alarm.s3_unauthorized_access.arn,
            aws_cloudwatch_metric_alarm.iam_policy_change.arn
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "EC2 CPU Utilization"
          period = 300
          metrics = [[
            "AWS/EC2", "CPUUtilization",
            "InstanceId", "${aws_instance.data_pipeline.id}"
          ]]
          view   = "timeSeries"
          stat   = "Average"
          region = var.region
          annotations = {
            horizontal = [{
              value = var.cpu_threshold_percent
              label = "Alarm threshold (${var.cpu_threshold_percent}%)"
              color = "#ff6961"
            }]
          }
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "S3 4xx Errors — Pipeline Bucket"
          period = 300
          region = var.region
          metrics = [[
            "AWS/S3", "4xxErrors",
            "BucketName", "${aws_s3_bucket.test_store.id}",
            "FilterId", "EntireBucket"
          ]]
          view = "timeSeries"
          stat = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 10
        width  = 24
        height = 6
        region = var.region
        properties = {
          title  = "IAM Policy Changes (CloudTrail)"
          period = 300
          region = var.region
          metrics = [[
            "SecureOps/Security", "IAMPolicyChangeCount"
          ]]
          view = "timeSeries"
          stat = "Sum"
          annotations = {
            horizontal = [{
              value = 1
              label = "Any change = alarm"
              color = "#ff6961"
            }]
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket.test_store, aws_instance.data_pipeline]
}
