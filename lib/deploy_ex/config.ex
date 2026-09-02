defmodule DeployEx.Config do
  @app :deploy_ex

  def iac_tool, do: Application.get_env(@app, :iac_tool) || "terraform"

  def cloud_provider, do: Application.get_env(@app, :cloud_provider, :aws)

  @doc """
  Reads one key from a non-AWS provider's config namespace (`config :deploy_ex, provider, ...`).

  Namespaced rather than flat because a non-AWS descriptor's `config_schema/0` validates that
  namespace strictly — a typo'd key fails at task start instead of mid-apply. The AWS keys stay
  flat and permissively validated so existing configs keep working.
  """
  @spec provider_setting(atom(), atom()) :: term()
  def provider_setting(provider, key), do: @app |> Application.get_env(provider, []) |> Keyword.get(key)

  @doc "Reads one key from the `:oci` config namespace. See `provider_setting/2`."
  @spec oci_setting(atom()) :: term()
  def oci_setting(key), do: provider_setting(:oci, key)

  # Follows the key layout already in use in the state bucket (oracle/<region>/<stack>/…),
  # so deploy_ex state sits alongside states written by other tooling without colliding.
  def oci_release_state_key do
    oci_setting(:release_state_key) ||
      "oracle/#{oci_setting(:region)}/#{DeployExHelpers.kebab_project_name()}-#{env()}/terraform.tfstate"
  end

  @default_env to_string(Mix.env())
  def env, do: Application.get_env(@app, :env) || @default_env
  def aws_region, do: Application.get_env(@app, :aws_region) || "us-west-2"

  def aws_log_region, do: Application.get_env(@app, :aws_log_region) || "us-west-2"

  @doc """
  Shared availability zone for monitoring/DB peer instances (Redis, Loki,
  Prometheus, Mimir, Sentry, Grafana) — pinned to one zone so every peer
  lands in the same AZ by construction, avoiding cross-AZ traffic and the
  DHCP/private_ip subnet mismatch these nodes used to ship with.

  Defaults to the given region's "a" zone; override with the
  `:aws_availability_zone` application env key.
  """
  def aws_availability_zone(region \\ aws_region()) do
    Application.get_env(@app, :aws_availability_zone) || "#{region}a"
  end

  def aws_log_bucket do
    Application.get_env(@app, :aws_log_bucket) ||
      "#{DeployExHelpers.kebab_project_name()}-backend-logs-#{env()}"
  end

  def aws_release_bucket do
    Application.get_env(@app, :aws_release_bucket) ||
      "#{DeployExHelpers.kebab_project_name()}-elixir-deploys-#{env()}"
  end

  def aws_release_state_bucket do
    Application.get_env(@app, :aws_release_state_bucket) ||
    "#{DeployExHelpers.kebab_project_name()}-elixir-release-state-#{env()}"
  end

  def qa_state_prefix do
    Application.get_env(@app, :qa_state_prefix, "qa-nodes")
  end

  def aws_release_state_lock_table do
    Application.get_env(@app, :aws_terraform_state_lock_table) ||
      "#{DeployExHelpers.kebab_project_name()}-terraform-state-lock-#{env()}"
  end

  def deploy_folder, do: Application.get_env(@app, :deploy_folder) || "./deploys"

  def aws_resource_group do
    Application.get_env(@app, :aws_resource_group) ||
      "#{DeployEx.Utils.upper_title_case(DeployExHelpers.project_name())} Backend"
  end

  def aws_project_name do
    Application.get_env(@app, :aws_project_name) ||
      DeployExHelpers.kebab_project_name()
  end

  def aws_iam_instance_profile do
    Application.get_env(@app, :aws_iam_instance_profile)
  end

  def aws_base_ami_name do
    Application.get_env(@app, :aws_base_ami_name, "debian-13")
  end

  def aws_base_ami_architecture do
    Application.get_env(@app, :aws_base_ami_architecture, "x86_64")
  end

  def aws_base_ami_owner do
    Application.get_env(@app, :aws_base_ami_owner, "136693071363")
  end

  def aws_security_group_id do
    Application.get_env(@app, :aws_security_group_id)
  end

  def aws_names_include_env? do
    Application.get_env(@app, :aws_names_include_env, false)
  end

  def tui_enabled?, do: Application.get_env(@app, :tui_enabled, true)

  def llm_provider, do: Application.get_env(@app, :llm_provider)

  def terraform_folder_path, do: Path.join(deploy_folder(), "terraform")
  def ansible_folder_path, do: Path.join(deploy_folder(), "ansible")

  def terraform_backend, do: Application.get_env(@app, :terraform_backend, :s3)

  def terraform_default_args(command) do
    result = @app
      |> Application.get_env(:terraform_default_args, [])
      |> Keyword.filter(fn {key, _} ->
        to_string(command) =~ Regex.compile!(to_string(key))
      end)

    case result do
      [] -> []
      [{_, _} | _] = args_map ->
        args_map
          |> Enum.reduce([], fn {_, args}, acc -> Keyword.merge(acc, args) end)
          |> Enum.reduce([], fn {key, value}, acc ->
            ["--#{String.replace(to_string(key), "_", "-")}", to_string(value) | acc]
          end)
    end
  end
end
