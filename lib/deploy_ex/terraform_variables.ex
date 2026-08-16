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



  def terraform_sentry_variables(opts, _provider) do
    if opts[:no_sentry] do
      ""
    else
      """
          sentry = {
            name                       = "Sentry Monitoring"
            instance_availability_zone = "#{opts[:availability_zone]}"

            tags = {
              Vendor = "Sentry"
              Type   = "Monitoring"
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
