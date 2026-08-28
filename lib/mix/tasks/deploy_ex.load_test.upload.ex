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

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, extra_args} = parse_args(args)

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required: mix deploy_ex.load_test.upload <app_name>")
      end

      with {:ok, runner} <- resolve_runner(opts),
           {:ok, scripts} <- collect_scripts(app_name, opts),
           {:ok, pem_file} <- DeployEx.Terraform.find_pem_file(@terraform_default_path, opts[:pem]) do
        ip = runner.public_ip || runner.ipv6_address

        if is_nil(ip) do
          Mix.raise("Runner has no reachable IP address")
        end

        case Enum.reduce_while(scripts, :ok, fn script, _acc ->
          case upload_script(script, ip, pem_file, opts) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end) do
          :ok ->
            unless opts[:quiet] do
              Mix.shell().info([:green, "\n✓ Uploaded #{length(scripts)} script(s) to #{ip}"])
            end

          {:error, reason} ->
            Mix.raise("Upload failed: #{reason}")
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

  defdelegate resolve_runner(opts, k6_runner_impl \\ DeployEx.K6Runner), to: DeployEx.K6Runner

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

  @doc """
  `user@host:path` scp target for a runner, resolved through `DeployEx.Cloud.ssh_user/1` so a
  non-AWS provider's default user (e.g. OCI's `ubuntu`) reaches this SSH transport.
  """
  def scp_target(ip, remote_path, opts \\ []), do: "#{DeployEx.Cloud.ssh_user(opts)}@#{ip}:#{remote_path}"

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
      scp_target(ip, remote_path, opts)
    ], stderr_to_stdout: true) do
      {_, 0} ->
        unless opts[:quiet] do
          Mix.shell().info([:green, "  ✓ ", :reset, filename])
        end

        :ok

      {output, _} ->
        Mix.shell().error("  ✗ Failed to upload #{filename}: #{output}")
        {:error, "#{filename}: #{output}"}
    end
  end
end
