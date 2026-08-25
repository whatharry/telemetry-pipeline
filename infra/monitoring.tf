# Alarms worth waking someone for. Each one corresponds to a specific failure the
# stack can actually experience -- an alarm that cannot be acted on is noise, and
# noise is how real alerts get ignored.

resource "aws_sns_topic" "alarms" {
  count = var.alarm_email == "" ? 0 : 1
  name  = "${var.project}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alarm_actions = var.alarm_email == "" ? [] : [aws_sns_topic.alarms[0].arn]
}

# The one that matters most: no healthy targets means the service is down, full
# stop. Everything else is a leading indicator; this is the outage itself.
resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name          = "${var.project}-no-healthy-targets"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  period              = 60
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.ingest.arn_suffix
  }

  alarm_description = "No healthy ingest tasks behind the ALB."
  alarm_actions     = local.alarm_actions
  ok_actions        = local.alarm_actions
}

# 5xx from the target means the app is up but erroring -- usually the database
# connection. Distinct from the alarm above and needs a different response.
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.project}-target-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 10
  period              = 300
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = { LoadBalancer = aws_lb.main.arn_suffix }

  alarm_description = "Ingest returning 5xx; check RDS connectivity first."
  alarm_actions     = local.alarm_actions
}

# Sustained high CPU on a single task means it is time to scale out. At
# desired_count = 1 this is advisory rather than actionable, which is why it is
# a separate alarm and not paged the same way.
resource "aws_cloudwatch_metric_alarm" "task_cpu" {
  alarm_name          = "${var.project}-ingest-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 80
  period              = 300
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.ingest.name
  }

  alarm_description = "Ingest CPU sustained above 80%; consider scaling out."
  alarm_actions     = local.alarm_actions
}

# RDS running out of disk is a silent killer -- writes start failing and the app
# looks broken for reasons that have nothing to do with the app.
resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name          = "${var.project}-db-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 2147483648 # 2 GiB
  period              = 300
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  treat_missing_data  = "notBreaching"

  dimensions = { DBInstanceIdentifier = aws_db_instance.main.identifier }

  alarm_description = "RDS free storage below 2 GiB."
  alarm_actions     = local.alarm_actions
}

# Cost guard. A demo left running is the classic way to discover AWS billing.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = "20"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.alarm_email == "" ? [] : [1]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = [var.alarm_email]
    }
  }
}
