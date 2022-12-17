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
  - `env` - Environment for terraform (default: `Mix.env()`)
  - `quiet` - Supress output
  - `force` - Force create files without asking
  - `verbose` - Log extra details about the process

  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)
      |> Keyword.put_new(:aws_region, @default_aws_region)
      |> Keyword.put_new(:aws_release_bucket, @default_aws_release_bucket)
      |> Keyword.put_new(:aws_log_bucket, DeployEx.Config.aws_log_bucket())
      |> Keyword.put_new(:env, Mix.env())

    opts = opts
      |> Keyword.put_new(:variables_file, Path.join(opts[:directory], "variables.tf"))
      |> Keyword.put_new(:keypair_file, Path.join(opts[:directory], "key-pair-main.tf"))
      |> Keyword.put_new(:outputs_file, Path.join(opts[:directory], "outputs.tf"))
      |> Keyword.put_new(:main_file, Path.join(opts[:directory], "main.tf"))

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         :ok <- ensure_terraform_directory_exists(opts[:directory]) do
      terraform_output = releases
        |> Keyword.keys
        |> Enum.map_join(",\n\n", &(&1 |> to_string |> generate_terraform_output))

      write_terraform_variables(terraform_output, opts)
      write_terraform_main(opts)
      write_terraform_output(opts)
      write_terraform_keypair(opts)
      run_terraform_init(opts)
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, v: :verbose],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        verbose: :boolean,
        aws_region: :string,
        env: :string,
        no_loki: :boolean,
        no_sentry: :boolean,
        no_grafana: :boolean,
        no_prometheus: :boolean
      ]
    )

    opts
  end

  defp run_terraform_init(opts) do
    DeployExHelpers.run_command_with_input("terraform init", opts[:directory])
  end

  defp ensure_terraform_directory_exists(directory) do
    if File.exists?(directory) do
      :ok
    else
      Mix.shell().info([:green, "* copying terraform into ", :reset, directory])

      File.mkdir_p!(directory)

      "terraform"
        |> DeployExHelpers.priv_file()
        |> File.cp_r!(directory)

      directory
        |> Path.join("**/*.eex")
        |> Path.wildcard
        |> Enum.map(&File.rm!/1)

      :ok
    end
  end

  defp generate_terraform_output(release_name) do
    String.trim_trailing("""
        #{release_name} = {
          name = "#{DeployExHelpers.upper_title_case(release_name)}"
          tags = {
            Vendor = "Self"
            Type   = "Self Made"
          }
        }
    """, "\n")
  end

  defp write_terraform_variables(terraform_output, opts) do
    if File.exists?(opts[:variables_file]) do
      opts[:variables_file]
        |> File.read!
        |> inject_terraform_contents_into_variables(terraform_output, opts)
    else
      :deploy_ex
        |> :code.priv_dir
        |> Path.join("terraform/variables.tf.eex")
        |> File.cp!("#{opts[:variables_file]}.eex")

      generate_and_delete_variables_template(terraform_output, opts)
    end
  end

  defp inject_terraform_contents_into_variables(current_file, terraform_output, opts) do
    current_file = String.split(current_file, "\n")
    project_variable_idx = Enum.find_index(
      current_file,
      &(&1 =~ "variable \"#{DeployExHelpers.underscored_app_name()}_project\"")
    ) + 4 # 4 is the number of newlines till the default key
    {start_of_file, project_variable} = Enum.split(current_file, project_variable_idx + 1)

    new_file = Enum.join(start_of_file ++ String.split(terraform_output, "\n") ++ Enum.take(project_variable, -3), "\n")

    if new_file !== current_file do
      opts = [{:message, [:green, "* injecting ", :reset, opts[:variables_file]]} | opts]

      DeployExHelpers.write_file(opts[:variables_file], new_file, opts)
    end
  end

  defp generate_and_delete_variables_template(terraform_output, opts) do
    template_file = :deploy_ex
      |> :code.priv_dir
      |> Path.join("terraform/variables.tf.eex")

    DeployExHelpers.check_file_exists!(template_file)

    variables_files = EEx.eval_file(template_file, assigns: %{
      environment: opts[:env],
      terraform_release_variables: terraform_output,
      release_bucket_name: opts[:aws_release_bucket],
      logging_bucket_name: opts[:aws_log_bucket],
      terraform_sentry_variables: terraform_sentry_variables(opts),
      terraform_grafana_variables: terraform_grafana_variables(opts),
      terraform_loki_variables: terraform_loki_variables(opts),
      terraform_prometheus_variables: terraform_prometheus_variables(opts),
      app_name: DeployExHelpers.underscored_app_name()
    })

    DeployExHelpers.write_file(opts[:variables_file], variables_files, opts)
  end

  defp terraform_sentry_variables(opts) do
    if opts[:no_sentry] do
      ""
    else
      """
          sentry = {
            name = "Sentry Monitoring"
            tags = {
              Vendor = "Sentry"
              Type   = "Monitoring"
            }
          },
      """
    end
  end

  defp terraform_loki_variables(opts) do
    if opts[:no_loki] do
      ""
    else
      """
          loki_aggreagtor = {
            name = "Grafana Loki Logs"
            instance_type = "t3.micro"
            enable_ebs                  = true
            instance_ebs_secondary_size = 8
            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "loki_logger"
            }
          },
      """
    end
  end

  defp terraform_grafana_variables(opts) do
    if opts[:no_grafana] do
      ""
    else
      """
          grafana_ui = {
            name                        = "Grafana UI"
            enable_ebs                  = true
            enable_eip                  = true
            instance_ebs_secondary_size = 8
            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "grafana_ui"
            }
          },
      """
    end
  end

  defp terraform_prometheus_variables(opts) do
    if opts[:no_prometheus] do
      ""
    else
      """
          prometheus_db = {
            name                        = "Prometheus Metrics Database"
            instance_type               = "t3.micro"
            enable_ebs                  = true
            instance_ebs_secondary_size = 16
            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "prometheus_db"
            }
          },
      """
    end
  end

  defp write_terraform_main(opts) do
    if File.exists?(opts[:main_file]) do
      rewrite_terraform_main_contents(opts)
    else
      generate_and_delete_main_template(opts)
    end
  end

  defp rewrite_terraform_main_contents(opts) do
    opts
      |> Keyword.put(:message, [
        :green, "* rewriting ", :reset, opts[:main_file]
      ])
      |> generate_and_delete_main_template
  end

  defp generate_and_delete_main_template(opts) do
    template_file_path = DeployExHelpers.priv_file("terraform/main.tf.eex")

    DeployExHelpers.check_file_exists!(template_file_path)

    main_file = EEx.eval_file(template_file_path, assigns: %{
      aws_region: opts[:aws_region],
      aws_release_bucket: opts[:aws_release_bucket],
      app_name: DeployExHelpers.underscored_app_name()
    })

    DeployExHelpers.write_file(opts[:main_file], main_file, opts)
  end

  defp write_terraform_output(opts) do
    keypair_template_path = DeployExHelpers.priv_file("terraform/outputs.tf.eex")

    DeployExHelpers.check_file_exists!(keypair_template_path)

    terraform_keypair = EEx.eval_file(keypair_template_path, assigns: %{
      app_name: DeployExHelpers.underscored_app_name()
    })

    DeployExHelpers.write_file(opts[:outputs_file], terraform_keypair, opts)
  end

  defp write_terraform_keypair(opts) do
    keypair_template_path = DeployExHelpers.priv_file("terraform/key-pair-main.tf.eex")

    DeployExHelpers.check_file_exists!(keypair_template_path)

    kebab_case_app_name = String.replace(DeployExHelpers.underscored_app_name(), "_", "-")
    random_bytes = 6 |> :crypto.strong_rand_bytes |> Base.encode32(padding: false)

    terraform_keypair = EEx.eval_file(keypair_template_path, assigns: %{
      pem_app_name: "#{kebab_case_app_name}-#{random_bytes}"
    })

    DeployExHelpers.write_file(opts[:keypair_file], terraform_keypair, opts)
  end
end
