variable vpc_id {}
variable account {}
variable subnets {}
variable environment {}
variable domain_name {}
variable aws_lb_arn {}
variable aws_lb_out_port {}
variable security_groups {}
variable execution_role_arn {}
variable aws_lb_certificate_arn {}

variable name_prefix {
  type = string
}
variable standard_tags {
  type = map(string)
}
variable cluster_name {
  type = string
}
variable cluster_arn {
  type = string
}
variable app_name {
  type = string
}
variable container_memory {
  type    = number
  default = 512
}
variable task_memory {
  type    = number
  default = null
}
variable container_cpu {
  type    = number
  default = 256
}
variable task_cpu {
  type    = number
  default = null
}
variable container_image {}
variable app_port {
  type    = number
  default = 9999
}
variable entrypoint {
  type    = list(string)
  default = null
}
variable command {
  type    = list(string)
  default = null
}
variable container_desired_count {
  type    = number
  default = 1
}
variable container_max_capacity {
  type    = number
  default = 1
}
variable container_min_capacity {
  type    = number
  default = 1
}
variable container_cpu_low_threshold {
  type    = number
  default = 60
}
variable container_cpu_high_threshold {
  type    = number
  default = 30
}
variable task_role_arn {
  type    = string
  default = null
}

variable retention_in_days {
  default = 7
}

variable healthcheck_path {
  type    = string
  default = "/health"
}
variable health_check_grace_period_seconds {
  type    = number
  default = null
}
variable launch_type {
  default = "FARGATE"
}
variable fargate_weight {
  default = 1
}
variable fargate_base {
  default = 1
}
variable fargate_spot_weight {
  default = 1
}
variable fargate_spot_base {
  default = 0
}
variable platform_version {
  type    = string
  default = "1.4.0" # Before: "LATEST"
}

variable additional_containers {
  description = "Additional containers definition"
  default = []
}

variable s3_log_bucket {
  type = string
}

variable public {
  default = false
}

variable mount_points {
  type = list(object({
    containerPath = string
    sourceVolume  = string
    readOnly      = bool
  }))
  description = "Container mount points. This is a list of maps, where each map should contain a `containerPath` and `sourceVolume`"
  default     = []
}

variable volumes {
  type = list(object({
    name      = string
    efs_volume_configuration = list(object({
      file_system_id          = string
      root_directory          = string
    }))
  }))
  description = "Task volume definitions as list of configuration objects"
  default     = []
}
