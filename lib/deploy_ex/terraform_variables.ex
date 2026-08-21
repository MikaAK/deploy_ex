defmodule DeployEx.TerraformVariables do
  @moduledoc """
  Generates the default `<app>_project` map and the support-node entries that go into a
  rendered variables.tf.

  Extracted because `Mix.Tasks.Terraform.Build` and `DeployEx.PrivRenderer` each carried
  their own copy, and they drifted: build was made provider-aware while the renderer kept
  emitting AWS-only keys. `mix deploy_ex.export_priv` on an OCI project therefore produced a
  variables.tf whose sizing fields the OCI instance module never reads — values that look
  authoritative and do nothing. One copy now, both callers.
  """

  def generate_terraform_release_variables(release_name, :oci) do
    String.trim_trailing("""
        #{release_name} = {
          name = "#{DeployEx.Utils.upper_title_case(release_name)}"
          tags = {
            Vendor = "Self"
            Type   = "Self Made"
          }

          # Sizing is optional — unset keys fall back to the instance_shape / instance_ocpus /
          # instance_memory_gbs variables at the top of this file.
          # shape                = "VM.Standard.E5.Flex"
          # ocpus                = 2
          # memory_gbs           = 16
          # boot_volume_size_gbs = 100
          # instance_count       = 2

          # Load balancer is optional — uncomment to front this app with an OCI Network Load
          # Balancer. Unlike AWS, OCI gates creation on `enable` alone (no instance_count /
          # autoscaling gate — see providers/oci/README.md). There is no `port` / `instance_port`
          # here: the listener is unconditionally 80 (and 443 when enable_https), matching what
          # AWS already does under the hood.
          # load_balancer = {
          #   enable            = true
          #   enable_https      = false
          #   reserved_ip_ocid  = null
          #
          #   health_check = {
          #     path                = "/health"
          #     return_code         = 200
          #     https_return_code   = 200
          #     unhealthy_threshold = 3
          #     timeout             = 3
          #     interval            = 10
          #   }
          # }
        }
    """, "\n")
  end
  def generate_terraform_release_variables(release_name, _provider) do
    String.trim_trailing("""
        #{release_name} = {
          name = "#{DeployEx.Utils.upper_title_case(release_name)}"
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
    """, "\n")
  end

  def terraform_redis_variables(opts, :oci) do
    if opts[:no_redis] do
      ""
    else
      """
          #{DeployExHelpers.underscored_project_name()}_redis = {
            name = "#{DeployExHelpers.title_case_project_name()} Redis"

            shape       = "VM.Standard.E5.Flex"
            ocpus       = 2
            memory_gbs  = 8

            boot_volume_size_gbs = 64

            tags = {
              Vendor      = "Redis"
              Type        = "Database"
              DatabaseKey = "#{DeployExHelpers.underscored_project_name()}_redis"
            }
          },
      """
    end
  end
  def terraform_redis_variables(opts, _provider) do
    if opts[:no_redis] do
      ""
    else
      """
          #{DeployExHelpers.underscored_project_name()}_redis = {
            name                       = "#{DeployExHelpers.title_case_project_name()} Redis"
            instance_availability_zone = "#{opts[:availability_zone]}"

            # This is a suggestion for instance

            instance_type = "r7g.medium"

            ebs = {
              enable_secondary = true
              secondary_size   = 16
            }

            tags = {
              Vendor      = "Redis"
              Type        = "Database"
              DatabaseKey = "#{DeployExHelpers.underscored_project_name()}_redis"
            }
          },
      """
    end
  end

  # Opt-in (--clickhouse), unlike redis: ClickHouse is not part of the default stack on either
  # provider — an AWS user hand-writes this entry — so an OCI render must not grow a node
  # nobody asked for. The DatabaseKey tag is what routes it into the database_*_clickhouse
  # inventory group the setup playbook targets.
  def terraform_clickhouse_variables(opts, :oci) do
    if opts[:clickhouse] do
      """
          #{DeployExHelpers.underscored_project_name()}_clickhouse = {
            name = "#{DeployExHelpers.title_case_project_name()} Clickhouse"

            shape       = "VM.Standard.E6.Flex"
            ocpus       = 2
            memory_gbs  = 16

            boot_volume_size_gbs = 200

            tags = {
              Vendor      = "ClickHouse"
              Type        = "Database"
              DatabaseKey = "#{DeployExHelpers.underscored_project_name()}_clickhouse"
            }
          },
      """
    else
      ""
    end
  end

  def terraform_clickhouse_variables(_opts, _provider), do: ""

  # Opt-in (--rabbitmq), same reasoning as clickhouse. Single node: the app declares quorum
  # queues, which are correct on one node (Raft majority of 1); more nodes buy HA and a
  # 2-node layout is the one to avoid. The DatabaseKey tag routes it into the
  # database_*_rabbitmq inventory group the setup playbook targets.
  def terraform_rabbitmq_variables(opts, :oci) do
    if opts[:rabbitmq] do
      """
          #{DeployExHelpers.underscored_project_name()}_rabbitmq = {
            name = "#{DeployExHelpers.title_case_project_name()} Rabbitmq"

            shape       = "VM.Standard.E6.Flex"
            ocpus       = 2
            memory_gbs  = 16

            boot_volume_size_gbs = 100

            tags = {
              Vendor      = "RabbitMQ"
              Type        = "Database"
              DatabaseKey = "#{DeployExHelpers.underscored_project_name()}_rabbitmq"
            }
          },
      """
    else
      ""
    end
  end

  def terraform_rabbitmq_variables(_opts, _provider), do: ""

  # OCI mirror of the AWS sizing below. 1 OCPU is 2 vCPU on the E-flex shapes, so
  # ocpus = 1 / memory_gbs = 8 is the same 2 vCPU / 8GB as t3.large and clears the same
  # errors-only floor. The oci-instance module has no secondary-volume key, so the capacity
  # AWS puts on a 64GB secondary EBS goes on the boot volume instead. `assign_public_ip` is
  # OCI's `enable_eip`, set for the reason grafana_ui sets it — the Sentry UI is browser-facing.
  def terraform_sentry_variables(opts, :oci) do
    if opts[:no_sentry] do
      ""
    else
      """
          sentry = {
            name = "Sentry Monitoring"

            shape       = "VM.Standard.E5.Flex"
            ocpus       = 1
            memory_gbs  = 8

            boot_volume_size_gbs = 100
            assign_public_ip     = true

            tags = {
              Vendor = "Sentry"
              Type   = "Monitoring"
              MonitoringKey = "sentry"
            }
          },
      """
    end
  end
  def terraform_sentry_variables(opts, _provider) do
    if opts[:no_sentry] do
      ""
    else
      """
          sentry = {
            name                       = "Sentry Monitoring"
            enable_eip                 = true
            instance_type              = "t3.large"
            instance_availability_zone = "#{opts[:availability_zone]}"

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
      """
    end
  end

  def terraform_loki_variables(opts, :oci) do
    if opts[:no_logging] do
      ""
    else
      """
          loki_aggregator = {
            name = "Grafana Loki Logs"

            shape       = "VM.Standard.E5.Flex"
            ocpus       = 1
            memory_gbs  = 4

            boot_volume_size_gbs = 64

            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "loki_logger"
            }
          },
      """
    end
  end
  def terraform_loki_variables(opts, _provider) do
    if opts[:no_logging] do
      ""
    else
      """
          loki_aggregator = {
            name                       = "Grafana Loki Logs"
            instance_type              = "t3.micro"
            instance_availability_zone = "#{opts[:availability_zone]}"

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
      """
    end
  end

  def terraform_grafana_variables(opts, :oci) do
    if opts[:no_grafana] do
      ""
    else
      """
          grafana_ui = {
            name = "Grafana UI"

            shape       = "VM.Standard.E5.Flex"
            ocpus       = 1
            memory_gbs  = 4

            boot_volume_size_gbs = 64
            assign_public_ip     = true

            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "grafana_ui"
            }
          },
      """
    end
  end
  def terraform_grafana_variables(opts, _provider) do
    if opts[:no_grafana] do
      ""
    else
      """
          grafana_ui = {
            name                       = "Grafana UI"
            enable_eip                 = true
            instance_availability_zone = "#{opts[:availability_zone]}"

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
      """
    end
  end

  def terraform_prometheus_variables(opts, :oci) do
    if opts[:no_prometheus] do
      ""
    else
      """
          prometheus_db = {
            name = "Prometheus Metrics Database"

            shape       = "VM.Standard.E5.Flex"
            ocpus       = 1
            memory_gbs  = 4

            boot_volume_size_gbs = 64

            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "prometheus_db"
            }
          },
      """
    end
  end
  def terraform_prometheus_variables(opts, _provider) do
    if opts[:no_prometheus] do
      ""
    else
      """
          prometheus_db = {
            name                       = "Prometheus Metrics Database"
            instance_type              = "t3.micro"
            instance_availability_zone = "#{opts[:availability_zone]}"

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
      """
    end
  end

end
