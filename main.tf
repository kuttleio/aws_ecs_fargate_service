# ---------------------------------------------------
#    CloudWatch Log Groups
# ---------------------------------------------------
resource aws_cloudwatch_log_group ecs_group {
  name              = "${var.name_prefix}/fargate/${var.cluster_name}/${var.service_name}/"
  tags              = var.standard_tags
  retention_in_days = var.retention_in_days
}


# ---------------------------------------------------
#    ECS Service
# ---------------------------------------------------
resource time_sleep wait {
  depends_on      = [aws_ecs_service.main]
  create_duration = "30s"
}

resource aws_ecs_service main {
  name                                = "${var.name_prefix}-${var.service_name}"
  cluster                             = var.cluster_arn
  propagate_tags                      = "SERVICE"
  deployment_maximum_percent          = 200
  deployment_minimum_healthy_percent  = 100
  desired_count                       = var.container_desired_count
  task_definition                     = aws_ecs_task_definition.main.arn
  health_check_grace_period_seconds   = var.health_check_grace_period_seconds
  tags                                = merge(var.standard_tags, { Name = var.service_name })
  
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
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = var.service_name
    container_port   = var.service_port
  }

  depends_on = [data.aws_lb.passed_on]
}


# ---------------------------------------------------
#    ECS Task Definition
# ---------------------------------------------------
module main_container_definition {
  source  = "cloudposse/ecs-container-definition/aws"
  version = "0.58.1"

  command                       = var.command
  container_name                = var.service_name
  container_image               = var.service_image
  container_memory              = var.container_memory
  container_memory_reservation  = var.container_memory
  container_cpu                 = var.container_cpu
  mount_points                  = var.mount_points
  entrypoint                    = var.entrypoint
  secrets                       = var.secrets

  port_mappings = [
    {
      containerPort = var.service_port
      hostPort      = var.service_port
      protocol      = "tcp"
    }
  ]

  environment = setunion(var.environment, 
  [
    {
      name  = "PORT"
      value = var.service_port
    },
    {
      name  = "APP_PORT"
      value = var.service_port
    },
    {
      name  = "SERVICE_PORT"
      value = var.service_port
    }    
  ])

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


# ---------------------------------------------------
#     Task Definition
# ---------------------------------------------------
resource aws_ecs_task_definition main {
  family                   = "${var.name_prefix}-${var.zenv_name}-${var.service_name}"
  requires_compatibilities = [var.launch_type]
  network_mode             = "awsvpc"
  execution_role_arn       = var.execution_role_arn
  cpu                      = coalesce(var.task_cpu, var.container_cpu)
  memory                   = coalesce(var.task_memory, var.container_memory)
  task_role_arn            = var.task_role_arn
  container_definitions    = jsonencode(concat([module.fargate_service_ecs_container_definition.json_map_object], var.additional_containers))
  tags                     = merge(var.standard_tags, tomap({ Name = var.service_name }))

  dynamic volume {
    for_each = var.volumes
    content {
      name = volume.value.name
      dynamic efs_volume_configuration {
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
#    Internal Load Balancer - If NOT Public
# ---------------------------------------------------
resource aws_lb_target_group main {
  name                          = "${var.name_prefix}-${var.zenv_name}-${var.service_name}-tg"
  port                          = var.service_port
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
    port                = var.service_port
  }
}

resource aws_lb_listener main {
  load_balancer_arn = data.aws_lb.passed_on.arn
  port              = var.public == true ? var.external_port : var.service_port
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-Ext-2018-06"
  certificate_arn   = var.aws_lb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

resource aws_lb_listener_rule block_header_rule {
  count         =  var.public == true ? 0 : 1
  listener_arn  = aws_lb_listener.main.arn
  priority      = 100

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
#    Public Load Balancer - If Public
# ---------------------------------------------------
resource aws_lb public {
  count               = var.public == true ? 1 : 0
  name                = "${var.name_prefix}-${var.zenv_name}-${var.service_name}-Pub-LB"
  load_balancer_type  = "application"
  security_groups     = var.security_groups
  subnets             = var.subnets

  access_logs {
    bucket  = var.s3_log_bucket
    prefix  = "${var.service_name}_lb"
    enabled = true
  }

  tags = merge(
    var.standard_tags,
    tomap({ Name = "Public-${var.service_name}" })
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
  count   = var.public == true && var.domain_record != null ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.name_prefix}-${var.zenv_name}-${var.service_name}"
  type    = "CNAME"
  ttl     = 300
  records = [aws_lb.public[0].dns_name]
}


# ---------------------------------------------------
#    LogDNA subsciprion
# ---------------------------------------------------
resource aws_cloudwatch_log_subscription_filter lambda_logfilter {
  count           = var.logdna_lambda_logs_arn != null ? 1 : 0
  name            = "${var.name_prefix}-${var.zenv_name}-${var.service_name}-filter"
  log_group_name  = "${var.name_prefix}/fargate/${var.cluster_name}/${var.service_name}/"
  filter_pattern  = ""
  destination_arn = var.logdna_lambda_logs_arn
  distribution    = "ByLogStream"
}
