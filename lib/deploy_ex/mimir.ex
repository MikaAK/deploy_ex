defmodule DeployEx.Mimir do
  @moduledoc """
  Single source of truth for Mimir render content shared between the real
  Mix tasks (`Mix.Tasks.Terraform.Build`, `Mix.Tasks.Ansible.Build`) and the
  render-only test harness (`DeployEx.PrivRenderer`).

  Kept in one place so a mutation is caught regardless of which caller a
  test happens to exercise, instead of silently drifting between two
  hand-duplicated copies.
  """

  @monitoring_setup_playbooks ["grafana_ui", "loki_log_aggregator", "prometheus_db"]

  @doc "Setup playbook node types that gain the grafana_alloy role line when mimir is enabled."
  def monitoring_setup_playbooks, do: @monitoring_setup_playbooks

  @doc "Whether mimir is enabled for this build (default ON, disabled via --no-mimir)."
  def enabled?(opts), do: not Keyword.get(opts, :no_mimir, false)

  @doc "Terraform variables.tf mimir_db block — empty string when mimir is disabled."
  def terraform_variables(opts) do
    if enabled?(opts) do
      """

          mimir_db = {
            name                        = "Mimir Metrics Database"
            instance_type               = "t3.small"
            enable_ebs                  = true
            instance_ebs_secondary_size = 16
            private_ip                  = "10.0.1.70"

            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "mimir_db"
            }
          },
      """
    else
      ""
    end
  end
end
