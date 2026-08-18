defmodule DeployEx.PrivRenderer do
  @moduledoc """
  Renders all priv EEx templates into a temp directory using the same
  variables as terraform.build and ansible.build. The output mirrors
  what a fresh build would produce in ./deploys/.
  """

  require Logger

  # SECTION: Public API

  @spec render_to_temp(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}
  def render_to_temp(opts \\ []) do
    temp_dir = create_temp_dir()

    result =
      try do
        with :ok <- render_terraform(temp_dir, opts),
             :ok <- render_ansible(temp_dir, opts) do
          {:ok, temp_dir}
        else
          {:error, _} = error -> error
        end
      rescue
        e ->
          {:error, ErrorMessage.internal_server_error(
            "failed to render priv templates: #{Exception.message(e)}"
          )}
      end

    case result do
      {:ok, _} -> result
      {:error, _} = error ->
        File.rm_rf!(temp_dir)
        error
    end
  end

  # SECTION: Terraform Rendering

  # Exports only the ACTIVE provider's file set, the same selection terraform.build uses. A
  # whole-directory copy put every provider's templates into the user's ./deploys — an :oci
  # project got the AWS tree plus an unrendered providers/oci/*.eex, and an :aws project got
  # providers/oci/*.tf sitting in its terraform root where tofu would try to load them.
  defp render_terraform(temp_dir, opts) do
    priv_terraform = priv_source_path("terraform")
    target_dir = Path.join(temp_dir, "terraform")
    provider = active_provider(opts)

    with {:ok, files} <- DeployEx.Cloud.PrivFileSet.files(provider, priv_terraform) do
      File.mkdir_p!(target_dir)

      copy_provider_files(priv_terraform, target_dir, files)

      render_provider_templates(priv_terraform, target_dir, files, build_terraform_params(opts, provider))
    end
  end

  defp copy_provider_files(priv_terraform, target_dir, files) do
    files
    |> Enum.reject(fn {source, _dest} -> String.ends_with?(source, ".eex") end)
    |> Enum.each(fn {source, dest} ->
      target = Path.join(target_dir, dest)

      target |> Path.dirname() |> File.mkdir_p!()
      File.cp!(Path.join(priv_terraform, source), target)
    end)
  end

  # Provider-scoped templates flatten on the way out — providers/oci/variables.tf.eex becomes
  # variables.tf at the terraform root — because tofu reads one directory, matching how
  # terraform.build writes them.
  defp render_provider_templates(priv_terraform, target_dir, files, params) do
    files
    |> Enum.filter(fn {source, _dest} -> String.ends_with?(source, ".eex") end)
    |> Enum.each(fn {source, dest} ->
      rendered = EEx.eval_file(Path.join(priv_terraform, source), assigns: params)
      target = Path.join(target_dir, String.replace_suffix(dest, ".eex", ""))

      target |> Path.dirname() |> File.mkdir_p!()
      File.write!(target, rendered)
    end)

    :ok
  end

  defp active_provider(opts), do: opts[:provider] || DeployEx.Config.cloud_provider()

  # Falls back to the shared template when a provider ships no variant, so a provider that
  # only overrides some files does not need copies of the rest.
  defp provider_template(priv_dir, provider, relative) do
    provider_path = Path.join([priv_dir, "providers", to_string(provider), relative])

    if File.exists?(provider_path) do
      provider_path
    else
      Path.join(priv_dir, relative)
    end
  end

  # AWS's inventory is a dynamic plugin config, so exporting it renders fully. OCI's is a
  # point-in-time snapshot generated from the live compartment, which export cannot know — it
  # is written EMPTY here on purpose, and `mix ansible.build` fills it in. Emitting a
  # plausible-looking inventory with invented hosts would be worse than an obviously empty one.
  defp render_inventory_template(priv_ansible, target_dir, provider, app_name) do
    case DeployEx.Cloud.inventory(provider) do
      {:ok, %{strategy: :aws_ec2_plugin, template: template, filename: filename}} ->
        render_template(
          Path.join(priv_ansible, Path.basename(template)),
          Path.join(target_dir, filename),
          %{app_name: app_name}
        )

      {:ok, %{template: template, filename: filename}} ->
        render_template(
          Path.join(priv_ansible, String.replace_prefix(template, "ansible/", "")),
          Path.join(target_dir, filename),
          %{hosts_section: "{}", children_section: "{}"}
        )

      {:error, _no_inventory} ->
        :ok
    end
  end

  defp build_terraform_params(opts, provider) do
    release_names = fetch_release_names()
    app_name = opts[:app_name] || DeployExHelpers.underscored_project_name()
    kebab_app_name = opts[:kebab_app_name] || DeployExHelpers.kebab_project_name()
    environment = opts[:environment] || DeployEx.Config.env()
    aws_region = opts[:aws_region] || DeployEx.Config.aws_region()
    aws_release_bucket = opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket()
    aws_log_bucket = opts[:aws_log_bucket] || DeployEx.Config.aws_log_bucket()

    availability_zone = opts[:availability_zone] || DeployEx.Config.aws_availability_zone(aws_region)
    opts = Keyword.put(opts, :availability_zone, availability_zone)

    terraform_app_releases_variables = release_names
      |> Enum.map_join(",\n\n", &DeployEx.TerraformVariables.generate_terraform_release_variables(&1, provider))

    random_bytes = 6 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false)

    %{
      directory: DeployEx.Config.terraform_folder_path(),
      environment: environment,
      aws_region: aws_region,
      aws_release_bucket: aws_release_bucket,

      use_db: not Keyword.get(opts, :no_database, false),
      db_password: "placeholder",

      release_bucket_name: aws_release_bucket,
      logging_bucket_name: aws_log_bucket,

      aws_release_state_bucket: DeployEx.Config.aws_release_state_bucket(),
      aws_release_state_lock_table: DeployEx.Config.aws_release_state_lock_table(),

      terraform_backend: DeployEx.Config.terraform_backend(),

      oci_region: DeployEx.Config.oci_setting(:region),
      oci_namespace: DeployEx.Config.oci_setting(:namespace),
      oci_state_bucket: DeployEx.Config.oci_setting(:release_state_bucket),
      oci_state_key: DeployEx.Config.oci_release_state_key(),
      oci_state_profile: DeployEx.Config.oci_setting(:state_profile),
      oci_vcn_cidr: DeployEx.Config.oci_setting(:vcn_cidr) || "10.20.0.0/16",

      pem_app_name: opts[:pem_app_name] || "#{kebab_app_name}-#{random_bytes}",
      app_name: app_name,
      kebab_app_name: kebab_app_name,

      use_loki: not Keyword.get(opts, :no_logging, false),
      use_grafana: not Keyword.get(opts, :no_grafana, false),
      use_prometheus: not Keyword.get(opts, :no_prometheus, false),
      use_redis: not Keyword.get(opts, :no_redis, false),
      use_sentry: not Keyword.get(opts, :no_sentry, false),
      use_database: not Keyword.get(opts, :no_database, false),

      terraform_app_releases_variables: terraform_app_releases_variables,
      terraform_release_variables: terraform_app_releases_variables,
      terraform_redis_variables: DeployEx.TerraformVariables.terraform_redis_variables(opts, provider),
      terraform_clickhouse_variables: DeployEx.TerraformVariables.terraform_clickhouse_variables(opts, provider),
      terraform_sentry_variables: DeployEx.TerraformVariables.terraform_sentry_variables(opts, provider),
      terraform_grafana_variables: DeployEx.TerraformVariables.terraform_grafana_variables(opts, provider),
      terraform_loki_variables: DeployEx.TerraformVariables.terraform_loki_variables(opts, provider),
      terraform_prometheus_variables: DeployEx.TerraformVariables.terraform_prometheus_variables(opts, provider),
      terraform_mimir_variables: DeployEx.Mimir.terraform_variables(opts)
    }
  end

  # SECTION: Ansible Rendering

  # The roles/setup/playbook templates are provider-neutral and ship to everyone, but the
  # provider-EXCLUSIVE subtree is stripped back out: leaving it would put an oci user's
  # ansible.cfg into an aws export and vice versa, and both are rendered fresh below.
  defp render_ansible(temp_dir, opts) do
    priv_ansible = priv_source_path("ansible")
    target_dir = Path.join(temp_dir, "ansible")

    with :ok <- copy_directory(priv_ansible, target_dir),
         :ok <- remove_eex_files_recursive(target_dir),
         :ok <- render_ansible_templates(priv_ansible, target_dir, opts) do
      File.rm_rf!(Path.join(target_dir, "providers"))

      :ok
    end
  end

  defp render_ansible_templates(priv_ansible, target_dir, opts) do
    app_name = opts[:app_name] || DeployExHelpers.underscored_project_name()
    provider = active_provider(opts)

    # ansible.cfg — the provider variant when one exists, since the OCI config sets a different
    # remote_user and points at a static inventory rather than the aws_ec2 plugin.
    ansible_cfg_vars = %{
      pem_file_path: "../terraform/#{String.replace(app_name, "_", "-")}*pem"
    }

    render_template(
      provider_template(priv_ansible, provider, "ansible.cfg.eex"),
      Path.join(target_dir, "ansible.cfg"),
      ansible_cfg_vars
    )

    render_inventory_template(priv_ansible, target_dir, provider, app_name)

    # group_vars/all.yaml
    group_vars_vars = %{
      is_logging_enabled: not Keyword.get(opts, :no_logging, false),
      is_prometheus_enabled: not Keyword.get(opts, :no_prometheus, false),
      is_mimir_enabled: DeployEx.Mimir.enabled?(opts),
      is_sentry_enabled: not Keyword.get(opts, :no_sentry, false),
      loki_logger_s3_region: DeployEx.Config.aws_log_region(),
      loki_logger_s3_bucket_name: DeployEx.Config.aws_log_bucket()
    }

    File.mkdir_p!(Path.join(target_dir, "group_vars"))

    render_template(
      Path.join(priv_ansible, "group_vars/all.yaml.eex"),
      Path.join(target_dir, "group_vars/all.yaml"),
      group_vars_vars
    )

    # Per-app playbooks
    release_names = fetch_release_names()

    File.mkdir_p!(Path.join(target_dir, "playbooks"))
    File.mkdir_p!(Path.join(target_dir, "setup"))

    Enum.each(release_names, fn release_name ->
      # cloud_provider is load-bearing in app_setup_playbook.yaml.eex — it selects awscli vs
      # oci_cli and gates the AWS-only save_ami role. Omitting it raised
      # "assign @cloud_provider not available" mid-render.
      playbook_vars = %{
        no_logging: Keyword.get(opts, :no_logging, false),
        no_prometheus: Keyword.get(opts, :no_prometheus, false),
        no_mimir: Keyword.get(opts, :no_mimir, false),
        cloud_provider: provider,
        app_name: release_name,
        port: 80
      }

      render_template(
        Path.join(priv_ansible, "app_playbook.yaml.eex"),
        Path.join(target_dir, "playbooks/#{release_name}.yaml"),
        playbook_vars
      )

      render_template(
        Path.join(priv_ansible, "app_setup_playbook.yaml.eex"),
        Path.join(target_dir, "setup/#{release_name}.yaml"),
        playbook_vars
      )
    end)

    # Remove the copied app-level EEx templates that shouldn't be in the output
    remove_if_exists(Path.join(target_dir, "app_playbook.yaml.eex"))
    remove_if_exists(Path.join(target_dir, "app_setup_playbook.yaml.eex"))

    render_monitoring_setup_playbooks(priv_ansible, target_dir, opts)

    :ok
  end

  defp render_monitoring_setup_playbooks(priv_ansible, target_dir, opts) do
    playbook_vars = %{use_mimir: DeployEx.Mimir.enabled?(opts)}

    Enum.each(DeployEx.Mimir.monitoring_setup_playbooks(), fn name ->
      output_path = Path.join(target_dir, "setup/#{name}.yaml")
      rendered = EEx.eval_file(Path.join(priv_ansible, "setup/#{name}.yaml.eex"), assigns: playbook_vars)

      if DeployEx.Mimir.should_write_setup_playbook?(output_path, rendered, opts) do
        File.mkdir_p!(Path.dirname(output_path))
        File.write!(output_path, rendered)
      end

      remove_if_exists("#{output_path}.eex")
    end)
  end

  # SECTION: Terraform Variable Generators

  defp priv_source_path(subdirectory) do
    :deploy_ex |> :code.priv_dir() |> Path.join(subdirectory)
  end

  defp create_temp_dir do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "deploy_ex_render_#{unique}")
    File.mkdir_p!(dir)
    dir
  end

  defp copy_directory(source, target) do
    File.mkdir_p!(target)
    File.cp_r!(source, target)
    :ok
  end

  defp remove_eex_files_recursive(directory) do
    directory
      |> Path.join("**/*.eex")
      |> Path.wildcard()
      |> Enum.each(&File.rm!/1)

    :ok
  end

  defp render_template(template_path, output_path, variables) do
    rendered = EEx.eval_file(template_path, assigns: variables)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, rendered)
  end

  defp remove_if_exists(path) do
    if File.exists?(path) do
      File.rm!(path)
    end
  end

  defp fetch_release_names do
    case DeployExHelpers.fetch_mix_release_names() do
      {:ok, names} -> Enum.map(names, &to_string/1)
      {:error, _} -> [DeployExHelpers.underscored_project_name()]
    end
  end
end
