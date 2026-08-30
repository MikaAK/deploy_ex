variable "environment" {
  description = "Name of the project in kebab case for use in names"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Name of the project in kebab case for use in names"
  type        = string
  default     = "deploy_ex"
}

variable "resource_group" {
  description = "Value of the Group tag for all resources"
  type        = string
  default     = "Deploy Ex Backend"
}

variable "enable_ipv4" {
  description = "Enables IPv4 for the VPC"
  type        = bool
  default     = false
}

variable "disable_ipv6" {
  description = "Disables IPv6 for the VPC"
  type        = bool
  default     = false
}

variable "github_token" {
  description = "GitHub personal access token for triggering workflows (optional)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_repo" {
  description = "GitHub repository in format 'owner/repo' for triggering setup workflows"
  type        = string
  default     = ""
}

variable "resource_databases" {
  description = "Map of database configurations"
  type = map(object({
    name              = string
    database_username = string

    instance_type            = optional(string)
    allocated_storage_gb     = optional(number)
    max_allocated_storage_gb = optional(number)
    backup_retention_period  = optional(number)
    backup_window            = optional(string)
    maintenance_window       = optional(string)
    multi_az                 = optional(bool)

    performance_insights_retention_period_days = optional(number)
    tags                                       = optional(map(string))
  }))

  default = {
    deploy_ex_db = {
      name              = "Deploy Ex Main"
      database_username = "deploy_ex"
    }
  }
}


variable "resource_buckets" {
  description = "Map of project names to buckets"
  type        = map(any)

  default = {
    logger = {
      bucket_name       = "deploy-ex-backend-logs-test"
      bucket_title_name = "Deploy Ex Backend Logs Test"
    },

    releases = {
      bucket_name       = "deploy-ex-elixir-deploys-test"
      bucket_title_name = "Deploy Ex Elixir Deploys Test"
    }
  }
}

variable "upload_buckets" {
  description = "Map of buckets to upload to"
  type = map(object({
    name                        = string
    bucket_cors_allowed_origins = optional(list(string))
    enable_cdn                  = optional(bool)
    cdn_subdomain               = optional(string)
    cdn_domain                  = optional(string)
    cdn_zone_id                 = optional(string)
    cdn_public_key_secret_name  = optional(string)

    tags = optional(map(string))
  }))

  default = {}
}

variable "deploy_ex_project" {
  description = "Map of project names to configuration."
  type        = map(object({
    name = string

    instance_count = optional(number)
    instance_type  = optional(string)
    instance_ami   = optional(string)

    private_ip                 = optional(string)
    instance_availability_zone = optional(string)
    enable_eip                 = optional(bool)
    disable_ipv6               = optional(bool)
    disable_public_ip          = optional(bool)

    preserve_eip_for_single_instance_asg = optional(bool)

    load_balancer = optional(object({
      enable       = optional(bool)
      enable_https = optional(bool)
      colocate_az  = optional(bool)

      port          = optional(number)
      instance_port = optional(number)

      health_check = optional(object({
        path          = optional(string)
        protocol      = optional(string)
        matcher       = optional(string)
        https_matcher = optional(string)

        unhealthy_threshold   = optional(number)
        healthy_threshold     = optional(number)
        timeout  = optional(number)
        interval = optional(number)
      }))
    }))

    ebs = optional(object({
      enable_secondary      = optional(bool)
      primary_size          = optional(number)
      secondary_size        = optional(number)
      secondary_snapshot_id = optional(string)
    }))

    autoscaling = optional(object({
      enable                       = optional(bool)
      min_size                     = optional(number)
      max_size                     = optional(number)
      desired_capacity             = optional(number)
      cpu_target_percent           = optional(number)
      scale_in_cooldown            = optional(number)
      scale_out_cooldown           = optional(number)
      switch_disable_delay_minutes = optional(number)
      ignore_capacity_changes      = optional(bool, false)

      templates = optional(map(object({
        instance_type           = string
        instance_ami            = optional(string)
        min_size                = optional(number)
        max_size                = optional(number)
        desired_capacity        = optional(number)
        ignore_capacity_changes = optional(bool, false)

        scheduling = optional(list(object({
          name       = string
          recurrence = string
          time_zone  = optional(string)

          changes = object({
            min_size         = optional(number)
            max_size         = optional(number)
            desired_capacity = optional(number)
          })
        })))
      })))
    }))

    app_port       = optional(number)
    use_latest_ami = optional(bool)

    tags = optional(map(string))
  }))

  default = {
    sentry = {
      name                       = "Sentry Monitoring"
      enable_eip                 = true
      instance_type              = "t3.large"
      instance_availability_zone = "us-west-2a"

      # Sized for getsentry/self-hosted's "errors-only" compose profile
      # (COMPOSE_PROFILES=errors-only in
      # priv/ansible/roles/sentry_server/templates/env.j2) — upstream's
      # install.sh hard-exits below 2 vCPU / 7000MB for that profile;
      # t3.large (2 vCPU / 8GB) clears it. The "feature-complete"
      # profile needs >= 4 vCPU / 14000MB (t3.large does NOT clear
      # this — a deterministic preflight exit, not an occasional
      # failure). To upgrade: raise instance_type here to >= 4
      # vCPU/14GB (e.g. t3.xlarge), set
      # COMPOSE_PROFILES=feature-complete in env.j2, then
      # `mix terraform.apply --target 'module.ec2_instance["sentry"]'`.
      ebs = {
        enable_secondary = true
        secondary_size   = 64
      }

      tags = {
        Vendor = "Sentry"
        Type   = "Monitoring"
        MonitoringKey = "sentry"
      }
    },

    deploy_ex_redis = {
      name                       = "Deploy Ex Redis"
      instance_availability_zone = "us-west-2a"

      # This is a suggestion for instance

      instance_type = "r7g.medium"

      ebs = {
        enable_secondary = true
        secondary_size   = 16
      }

      tags = {
        Vendor      = "Redis"
        Type        = "Database"
        DatabaseKey = "deploy_ex_redis"
      }
    },

    grafana_ui = {
      name                       = "Grafana UI"
      enable_eip                 = true
      instance_availability_zone = "us-west-2a"

      ebs = {
        enable_secondary = true
        secondary_size   = 8
      }

      tags = {
        Vendor = "Grafana"
        Type   = "Monitoring"
        MonitoringKey = "grafana_ui"
      }
    },

    prometheus_db = {
      name                       = "Prometheus Metrics Database"
      instance_type              = "t3.micro"
      instance_availability_zone = "us-west-2a"

      ebs = {
        enable_secondary = true
        secondary_size   = 16
      }

      tags = {
        Vendor = "Grafana"
        Type   = "Monitoring"
        MonitoringKey = "prometheus_db"
      }
    },

    loki_aggregator = {
      name                       = "Grafana Loki Logs"
      instance_type              = "t3.micro"
      instance_availability_zone = "us-west-2a"

      ebs = {
        enable_secondary = true
        secondary_size   = 8
      }

      tags = {
        Vendor = "Grafana"
        Type   = "Monitoring"
        MonitoringKey = "loki_logger"
      }
    },

    deploy_ex = {
      name = "Deploy Ex"
      tags = {
        Vendor = "Self"
        Type   = "Self Made"
      }

      # Autoscaling Configuration (optional)
      # Uncomment and configure to enable AWS Auto Scaling Groups
      # autoscaling = {
      #   enable             = true
      #   min_size           = 1
      #   max_size           = 5
      #   desired_capacity   = 2
      #   cpu_target_percent = 60
      # }
    }
  }
}
