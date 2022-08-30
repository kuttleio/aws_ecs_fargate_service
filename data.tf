data aws_region current {}
data aws_caller_identity current {}

data aws_lb passed_on {
    arn = var.aws_lb_arn
}

data aws_acm_certificate main {
    domain      = "*.${var.domain_name}"
    statuses    = ["ISSUED"]
    most_recent = true
}

data aws_route53_zone main {
    name = var.domain_name
}
