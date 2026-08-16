defmodule Mix.Tasks.Terraform.Build do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()
  @default_aws_region DeployEx.Config.aws_region()

  @default_aws_release_bucket DeployEx.Config.aws_release_bucket()
  @default_aws_log_bucket DeployEx.Config.aws_log_bucket()

  @shortdoc "Builds/Updates terraform files or adds it to your project"
  @moduledoc """
  Builds or updates terraform files within the project.

  ## Options
  - `directory` - Directory for the terraform files (default: `#{@terraform_default_path}`)
  - `aws-region` - Region for aws (default: `#{@default_aws_region}`)
  - `aws-bucket` - Region for aws (default: `#{@default_aws_release_bucket}`)
  - `aws-log-bucket` - Region for aws (default: `#{@default_aws_log_bucket}`)
  - `availability-zone` - Shared AZ for monitoring/DB peer instances (default: aws-region's "a" zone)
  - `env` - Environment for terraform (default: `Mix.env()`)
  - `render-dir` - Render the terraform files into this directory instead of
    `directory`, skipping the tool preflight and `terraform init`. Used by the
    render diff harness to compare output across revisions.
  - `quiet` - Supress output
  - `force` - Force create files without asking
  - `verbose` - Log extra details about the process

  """

  def run(args) do
    opts = build_opts(args)

    # --provider overrides the configured cloud_provider. Resolved once so the seed and the
    # render can never disagree about which file set they are working from.
    provider = resolve_provider(opts)

    with :ok <- DeployExHelpers.check_valid_project(),
         :ok <- ensure_terraform_installed(opts),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         :ok <- ensure_terraform_directory_exists(opts[:directory], provider) do
      random_bytes = 6 |> :crypto.strong_rand_bytes |> Base.encode32(padding: false)

      terraform_app_releases_variables = releases
        |> Keyword.keys
        |> Enum.map_join(",\n\n", &DeployEx.TerraformVariables.generate_terraform_release_variables(to_string(&1), provider))

      params = %{
        directory: opts[:directory],
        environment: opts[:env],

        aws_region: opts[:aws_region],
        aws_release_bucket: opts[:aws_release_bucket],

        use_db: !opts[:no_database],
        db_password: !opts[:no_database] && (opts[:db_password] || generate_db_password()),

        release_bucket_name: opts[:aws_release_bucket],
        logging_bucket_name: opts[:aws_log_bucket],

        aws_release_state_bucket: opts[:aws_release_state_bucket],
        aws_release_state_lock_table: opts[:aws_release_state_lock_table],

        terraform_backend: DeployEx.Config.terraform_backend(),

        pem_app_name: opts[:pem_app_name] || "#{DeployExHelpers.kebab_project_name()}-#{random_bytes}",
        app_name: DeployExHelpers.underscored_project_name(),
        kebab_app_name: DeployExHelpers.kebab_project_name(),

        use_loki: !opts[:no_logging],
        use_grafana: !opts[:no_grafana],
        use_prometheus: !opts[:no_prometheus],
        use_redis: !opts[:no_redis],
        use_sentry: !opts[:no_sentry],
        use_database: !opts[:no_database],

        terraform_app_releases_variables: terraform_app_releases_variables,
        terraform_release_variables: terraform_app_releases_variables,
        terraform_redis_variables: DeployEx.TerraformVariables.terraform_redis_variables(opts, provider),
        terraform_sentry_variables: DeployEx.TerraformVariables.terraform_sentry_variables(opts, provider),
        terraform_grafana_variables: DeployEx.TerraformVariables.terraform_grafana_variables(opts, provider),
        terraform_loki_variables: DeployEx.TerraformVariables.terraform_loki_variables(opts, provider),
        terraform_prometheus_variables: DeployEx.TerraformVariables.terraform_prometheus_variables(opts, provider),
        terraform_mimir_variables: DeployEx.Mimir.terraform_variables(opts),
      }

      write_terraform_template_files(params, opts, provider)

      if opts[:render_dir] do
        :ok
      else
        DeployEx.Terraform.run_command_with_input(
          "init",
          params[:directory]
        )
      end
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  @doc false
  def build_opts(args) do
    opts = args
      |> parse_args
      |> put_render_dir_paths()
      |> Keyword.put_new(:directory, @terraform_default_path)
      |> Keyword.put_new(:aws_region, @default_aws_region)
      |> Keyword.put_new(:aws_release_bucket, @default_aws_release_bucket)
      |> Keyword.put_new(:aws_log_bucket, DeployEx.Config.aws_log_bucket())
      |> Keyword.put_new(:aws_release_state_bucket, DeployEx.Config.aws_release_state_bucket())
      |> Keyword.put_new(:aws_release_state_lock_table, DeployEx.Config.aws_release_state_lock_table())
      |> Keyword.put_new(:env, Mix.env())

    no_logging = opts[:no_logging] || opts[:no_loki] || false
    opts = Keyword.put(opts, :no_logging, no_logging)

    Keyword.put_new(opts, :availability_zone, DeployEx.Config.aws_availability_zone(opts[:aws_region]))
  end

  # Matches the flag against the registered providers rather than calling to_existing_atom/1.
  # That function depends on whether something has already interned the atom, which is not
  # guaranteed here — DeployEx.Cloud's registry is a compile-time attribute and the module may
  # not be loaded yet when this task runs. Matching known keys also gives a usable error.
  defp resolve_provider(opts) do
    case opts[:provider] do
      nil ->
        DeployEx.Config.cloud_provider()

      name ->
        known = DeployEx.Cloud.providers()

        case Enum.find(known, &(to_string(&1) === name)) do
          nil -> Mix.raise("unknown provider #{inspect(name)}, expected one of #{inspect(known)}")
          provider -> provider
        end
    end
  end

  defp put_render_dir_paths(opts) do
    case opts[:render_dir] do
      nil -> opts
      render_dir -> Keyword.put(opts, :directory, render_dir)
    end
  end

  defp ensure_terraform_installed(opts) do
    if opts[:render_dir] do
      :ok
    else
      DeployEx.ToolInstaller.ensure_installed(:terraform)
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, v: :verbose],
      switches: [
        directory: :string,
        render_dir: :string,
        provider: :string,
        pem_app_name: :string,
        db_password: :string,
        force: :boolean,
        quiet: :boolean,
        verbose: :boolean,
        aws_region: :string,
        availability_zone: :string,
        env: :string,
        no_database: :boolean,
        no_logging: :boolean,
        no_loki: :boolean,
        no_sentry: :boolean,
        no_grafana: :boolean,
        no_redis: :boolean,
        no_prometheus: :boolean,
        no_mimir: :boolean
      ]
    )

    opts
  end

  # Seeds only the active provider's file set. A whole-tree copy would put every provider's
  # templates into every user's ./deploys — an :aws user would find providers/oci/*.tf sitting
  # in their terraform root, where tofu would try to load them.
  defp ensure_terraform_directory_exists(directory, provider) do
    if File.exists?(directory) do
      :ok
    else
      Mix.shell().info([:green, "* copying ", to_string(provider), " terraform into ", :reset, directory])

      priv_path = DeployExHelpers.priv_folder("terraform")

      with {:ok, files} <- DeployEx.Cloud.PrivFileSet.files(provider, priv_path) do
        File.mkdir_p!(directory)

        files
        |> Enum.reject(fn {source, _dest} -> String.ends_with?(source, ".eex") end)
        |> Enum.each(fn {source, dest} -> copy_priv_file(priv_path, directory, source, dest) end)

        :ok
      end
    end
  end

  defp copy_priv_file(priv_path, directory, source, dest) do
    target = Path.join(directory, dest)

    target |> Path.dirname() |> File.mkdir_p!()
    File.cp!(Path.join(priv_path, source), target)
  end

  # The AWS block advertises autoscaling, which has no OCI implementation yet — leaving that
  # comment in an OCI tree would document a knob that silently does nothing.
  defp generate_db_password do
    "SuperSecretPassword#{Enum.random(111_111..999_999)}"
  end

  # Renders the active provider's .eex files. Non-AWS templates flatten on the way out —
  # providers/oci/variables.tf.eex becomes variables.tf at the terraform root — because tofu
  # only loads root-level .tf and runs in the configured terraform folder.
  defp write_terraform_template_files(params, opts, provider) do
    terraform_path = DeployExHelpers.priv_folder("terraform")

    with {:ok, files} <- DeployEx.Cloud.PrivFileSet.files(provider, terraform_path) do
      files
      |> Enum.filter(fn {source, _dest} -> String.ends_with?(source, ".eex") end)
      |> Enum.each(fn {source, dest} ->
        template = EEx.eval_file(Path.join(terraform_path, source), assigns: params)
        target = Path.join(params[:directory], String.replace(dest, ".eex", ""))

        target |> Path.dirname() |> File.mkdir_p!()
        DeployExHelpers.write_file(target, template, opts)
      end)

      :ok
    end
  end
end
