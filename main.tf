# ---------------------------------------------------
#    CloudWatch Log Groups
# ---------------------------------------------------
resource aws_cloudwatch_log_group ecs_group {
  name = "${var.name_prefix}/fargate/${var.cluster_name}/${var.app_name}/"
  tags = var.standard_tags
}


# ---------------------------------------------------
#    ECS Service
# ---------------------------------------------------
resource aws_ecs_service aws_ecs_fargate_service {
  name                                = "${var.name_prefix}-${var.app_name}"
  cluster                             = var.cluster_arn
  platform_version                    = var.platform_version
  propagate_tags                      = "SERVICE"
  deployment_maximum_percent          = 200
  deployment_minimum_healthy_percent  = 100
  desired_count                       = var.container_desired_count
  task_definition                     = aws_ecs_task_definition.fargate_service_task_definition.arn
  health_check_grace_period_seconds   = var.health_check_grace_period_seconds
  tags                                = merge(var.standard_tags, { Name = var.app_name })
  
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = var.fargate_weight
    base              = var.fargate_base
  }
  
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = var.fargate_spot_weight
    base              = var.fargate_spot_base
  }

  network_configuration {
    security_groups  = var.security_groups
    subnets          = var.subnets
    assign_public_ip = var.public
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.aws_ecs_fargate_service_target_group.arn
    container_name   = var.app_name
    container_port   = var.app_port
  }
}


# ---------------------------------------------------
#    ECS Task Definition
# ---------------------------------------------------
module fargate_service_ecs_container_definition {
  source                        = "cloudposse/ecs-container-definition/aws"
  version                       = "0.58.1"
  command                       = var.command
  container_name                = var.app_name
  container_image               = var.container_image
  container_memory              = var.container_memory
  container_memory_reservation  = var.container_memory
  container_cpu                 = var.container_cpu
  mount_points                  = var.mount_points
  entrypoint                    = var.entrypoint
  environment                   = setunion(var.environment, 
  [
    {
      name  = "PORT"
      value = var.app_port
    },
    {
      name  = "APP_PORT"
      value = var.app_port
    }
  ])

  port_mappings = [
    {
      containerPort = var.app_port
      hostPort      = var.app_port
      protocol      = "tcp"
    }]

  log_configuration = {
    logDriver     = "awslogs"
    secretOptions = null
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.ecs_group.name,
      "awslogs-region"        = data.aws_region.current.name,
      "awslogs-stream-prefix" = "ecs"
    }
  }
}

resource aws_ecs_task_definition fargate_service_task_definition {
  family                   = "${var.name_prefix}-${var.app_name}"
  requires_compatibilities = [var.launch_type]
  network_mode             = "awsvpc"
  execution_role_arn       = var.execution_role_arn
  cpu                      = coalesce(var.task_cpu, var.container_cpu)
  memory                   = coalesce(var.task_memory, var.container_memory)
  task_role_arn            = var.task_role_arn

  container_definitions    = jsonencode(concat([module.fargate_service_ecs_container_definition.json_map_object], var.additional_containers))
  tags                     = var.standard_tags

  dynamic "volume" {
    for_each = var.volumes
    content {
      name = volume.value.name
      dynamic "efs_volume_configuration" {
        for_each = lookup(volume.value, "efs_volume_configuration", [])
        content {
          file_system_id      = lookup(efs_volume_configuration.value, "file_system_id", null)
          root_directory      = lookup(efs_volume_configuration.value, "root_directory", null)
          transit_encryption  = "ENABLED"
        }
      }
    }
  }
}


# ---------------------------------------------------
#    CloudWatch Alarms for ASG
# ---------------------------------------------------
resource aws_cloudwatch_metric_alarm fargate_service_cpu_high {
  alarm_name          = "${var.name_prefix}-fargate-high-cpu-${var.app_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  threshold           = var.container_cpu_high_threshold
  datapoints_to_alarm = 1
  statistic           = "Average"
  period              = "60"

  metric_name = "CPUUtilization"
  namespace   = "AWS/ECS"
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = aws_ecs_service.aws_ecs_fargate_service.name
  }

  alarm_actions = [
    aws_appautoscaling_policy.fargate_service_scale_up.arn
  ]
}

resource aws_cloudwatch_metric_alarm fargate_service_cpu_low {
  alarm_name          = "${var.name_prefix}-fargate-low-cpu-${var.app_name}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  threshold           = var.container_cpu_low_threshold
  datapoints_to_alarm = 1
  statistic           = "Average"
  period              = "60"

  metric_name = "CPUUtilization"
  namespace   = "AWS/ECS"
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = aws_ecs_service.aws_ecs_fargate_service.name
  }

  alarm_actions = [
    aws_appautoscaling_policy.fargate_service_scale_down.arn
  ]
}


# ---------------------------------------------------
#    Autoscaling
# ---------------------------------------------------
resource time_sleep wait {
  depends_on      = [aws_ecs_service.aws_ecs_fargate_service]
  create_duration = "30s"
}

resource aws_appautoscaling_target fargate_service_autoscaling_target {
  min_capacity        = var.container_min_capacity
  max_capacity        = var.container_max_capacity
  resource_id         = "service/${var.cluster_name}/${var.name_prefix}-${var.app_name}"
  role_arn            = "arn:aws:iam::${var.account}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService"
  scalable_dimension  = "ecs:service:DesiredCount"
  service_namespace   = "ecs"
  depends_on          = [time_sleep.wait]
}

resource aws_appautoscaling_policy fargate_service_scale_up {
  name               = "scale-up-${var.app_name}"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.fargate_service_autoscaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.fargate_service_autoscaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.fargate_service_autoscaling_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource aws_appautoscaling_policy fargate_service_scale_down {
  name               = "scale-down-${var.app_name}"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.fargate_service_autoscaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.fargate_service_autoscaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.fargate_service_autoscaling_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = -1
    }
  }
}


# ---------------------------------------------------
#    Internal Load Balancer - If Private Subnet
# ---------------------------------------------------
resource aws_lb_target_group aws_ecs_fargate_service_target_group {
  name                          = "${var.name_prefix}-${var.app_name}-tg"
  port                          = var.app_port
  protocol                      = "HTTP"
  vpc_id                        = var.vpc_id
  load_balancing_algorithm_type = "round_robin"
  target_type                   = "ip"
  depends_on                    = [data.aws_lb.passed_on]
  
  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
    path                = var.healthcheck_path
    port                = var.app_port
  }
}

resource aws_lb_listener aws_ecs_fargate_service_aws_lb_listener {
  load_balancer_arn = var.aws_lb_arn
  port              = var.aws_lb_out_port
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-Ext-2018-06"
  certificate_arn   = var.aws_lb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aws_ecs_fargate_service_target_group.arn
  }
}

resource "aws_lb_listener_rule" "block_header_rule" {
  listener_arn = aws_lb_listener.aws_ecs_fargate_service_aws_lb_listener.arn
  priority = 100

  condition {
      http_header {
        http_header_name = "X-Forwarded-Host"
        values           = ["*"]
      }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type  = "text/plain"
      message_body  = "Invalid host header."
      status_code   = 400
    }
  }
}


# ---------------------------------------------------
#    Public Load Balancer - If Public Subnet
# ---------------------------------------------------
resource aws_lb public {
  count               = var.public == true ? 1 : 0
  name                = "${var.name_prefix}-Pub-${var.app_name}-LB"
  load_balancer_type  = "application"
  security_groups     = var.security_groups
  subnets             = var.subnets

  access_logs {
    bucket  = var.s3_log_bucket
    prefix  = "${var.app_name}_lb"
    enabled = true
  }

  tags = merge(
    var.standard_tags,
    tomap({ Name = "Public-${var.app_name}" })
  )
}

resource aws_lb_listener public {
  count             = var.public == true ? 1 : 0
  load_balancer_arn = aws_lb.public[0].arn
  port              = 80
  protocol          = "HTTP"
  depends_on        = [aws_lb.public]

  default_action {
    type = "redirect"

    redirect {
      port        = 443
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource aws_lb_listener_rule block_header {
  count         = var.public == true ? 1 : 0
  listener_arn  = aws_lb_listener.public[0].arn
  priority      = 100
  depends_on    = [aws_lb.public]

  condition {
      http_header {
        http_header_name = "X-Forwarded-Host"
        values           = ["*"]
      }
  }
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Invalid host header."
      status_code = 400
    }
  }
}


# ---------------------------------------------------
#    DNS Record (CNAME)
# ---------------------------------------------------
resource aws_route53_record main {
  count   = var.public == true ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.name_prefix}-${var.app_name}"
  type    = "CNAME"
  ttl     = 300
  records = [aws_lb.public[0].dns_name]
}
