defmodule Mix.Tasks.DeployEx.LoadTest.Upload do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Uploads k6 scripts to a runner"
  @moduledoc """
  Uploads k6 test scripts to a k6 runner instance via SCP.

  By default uploads all scripts from `deploys/k6/scripts/<app_name>/`.
  Use `--script` to upload a specific file.

  ## Example
  ```bash
  mix deploy_ex.load_test.upload my_app
  mix deploy_ex.load_test.upload my_app --script deploys/k6/scripts/my_app/load_test.js
  mix deploy_ex.load_test.upload my_app --instance-id i-0abc123
  ```

  ## Options
  - `--script` - Path to specific script file (default: all in deploys/k6/scripts/<app>/)
  - `--instance-id, -i` - Specific runner instance ID
  - `--pem` - Path to PEM file
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required: mix deploy_ex.load_test.upload <app_name>")
      end

      with {:ok, runner} <- find_runner(opts),
           {:ok, scripts} <- collect_scripts(app_name, opts),
           {:ok, pem_file} <- DeployEx.Terraform.find_pem_file(@terraform_default_path, opts[:pem]) do
        ip = runner.public_ip || runner.ipv6_address

        if is_nil(ip) do
          Mix.raise("Runner has no reachable IP address")
        end

        Enum.each(scripts, fn script ->
          upload_script(script, ip, pem_file, opts)
        end)

        unless opts[:quiet] do
          Mix.shell().info([:green, "\n✓ Uploaded #{length(scripts)} script(s) to #{ip}"])
        end
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [i: :instance_id, q: :quiet],
      switches: [
        script: :string,
        instance_id: :string,
        pem: :string,
        quiet: :boolean
      ]
    )
  end

  defp find_runner(opts) do
    case opts[:instance_id] do
      nil ->
        case DeployEx.K6Runner.fetch_all_runners(opts) do
          {:ok, [runner | _]} ->
            DeployEx.K6Runner.verify_instance_exists(runner)

          {:ok, []} ->
            {:error, ErrorMessage.not_found("no k6 runners found, create one with: mix deploy_ex.load_test.create_instance")}

          error ->
            error
        end

      instance_id ->
        DeployEx.K6Runner.fetch_state(instance_id, opts)
    end
  end

  defp collect_scripts(app_name, opts) do
    case opts[:script] do
      nil ->
        dir = Path.join(["deploys", "k6", "scripts", app_name])

        if File.dir?(dir) do
          scripts = dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".js"))
          |> Enum.map(&Path.join(dir, &1))

          if Enum.empty?(scripts) do
            {:error, ErrorMessage.not_found("no .js scripts found in #{dir}")}
          else
            {:ok, scripts}
          end
        else
          {:error, ErrorMessage.not_found(
            "script directory not found: #{dir}\n" <>
            "Run: mix deploy_ex.load_test.init #{app_name}"
          )}
        end

      script_path ->
        if File.exists?(script_path) do
          {:ok, [script_path]}
        else
          {:error, ErrorMessage.not_found("script not found: #{script_path}")}
        end
    end
  end

  defp upload_script(script_path, ip, pem_file, opts) do
    filename = Path.basename(script_path)
    remote_path = "/srv/k6/scripts/#{filename}"

    unless opts[:quiet] do
      Mix.shell().info([:faint, "Uploading ", :reset, filename, :faint, " → ", :reset, remote_path])
    end

    abs_pem = Path.expand(pem_file)

    case System.cmd("scp", [
      "-i", abs_pem,
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      script_path,
      "admin@#{ip}:#{remote_path}"
    ], stderr_to_stdout: true) do
      {_, 0} ->
        unless opts[:quiet] do
          Mix.shell().info([:green, "  ✓ ", :reset, filename])
        end

      {output, _} ->
        Mix.shell().error("  ✗ Failed to upload #{filename}: #{output}")
    end
  end
end
