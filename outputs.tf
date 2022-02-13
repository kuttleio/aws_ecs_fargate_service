output "load_balancer_arn" {
    value = var.public == true ? aws_lb.public[0].arn : null
}

output "load_balancer_fqdn" {
    value = var.public == true ? aws_lb.public[0].dns_name : null
}

# output "name" {
#     value = aws_route53_record.main[0].name
# }

# output "fqdn" {
#     value = aws_route53_record.main[0].fqdn
# }

output "app_port" {
    value = var.app_port
}

output cloudwatch_log_group_name {
    value = aws_cloudwatch_log_group.ecs_group.name
}
