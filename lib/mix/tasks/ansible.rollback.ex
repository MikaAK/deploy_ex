defmodule Mix.Tasks.Ansible.Rollback do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Rollsback an ansible host to a previous sha"
  @moduledoc """
  Deploys a specific release from S3, if no sha is given chooses the last sha.

  This will load your target or release before last onto each node and sets it up
  in a SystemD task.

  ## Example
  ```bash
  mix ansible.rollback my_app
  mix ansible.rollback my_app --select
  mix ansible.rollback my_app --sha 2ac12b
  ```

  ## Options
  - `directory` - Directory containing terraform playbooks (default: #{@terraform_default_path})
  - `copy-json-env-file` - Copy environment file and load into host environments
  - `target-sha` - Target github sha
  - `quiet` - Suppress output messages
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, node_name_args} = parse_args(args)

      opts = opts
        |> Keyword.put_new(:directory, @terraform_default_path)
        |> Keyword.put_new(:aws_region, DeployEx.Config.aws_region())
        |> Keyword.put_new(:aws_release_bucket, DeployEx.Config.aws_release_bucket())

      with {:ok, app_name} <- DeployExHelpers.find_project_name(node_name_args),
           _ = Mix.shell().info([:yellow, "Fetching ", :bright, app_name, :reset, :yellow, " releases from S3..."]),
           {:ok, releases} <- DeployEx.ReleaseUploader.fetch_all_remote_releases(opts),
           {:ok, pem} <- DeployEx.Terraform.find_pem_file(opts[:directory], opts[:pem]),
           {:ok, latest_releases} <- fetch_app_release_history(app_name, pem, opts),
           {:ok, latest_shas} <- parse_and_check_any_releases(latest_releases),
           {:ok, target_sha} <- validate_target_sha_release_exists(releases, select_target_sha(latest_shas, opts)) do
        Mix.shell().info([
          :yellow, "Starting rollback to ", :bright, target_sha, :reset, :yellow, " for ", :bright, app_name, :reset
        ])

        with :ok <- Mix.Tasks.Ansible.Deploy.run(["-t", target_sha, "--only", app_name])  |> IO.inspect do
          Mix.shell().info([
            :green, "Rollback completed to ", :bright, target_sha, :reset,
            :green, " for ", :bright, app_name, :reset
          ])
        end
      else
        {:error, error} -> Mix.raise(to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet, d: :directory, p: :pem, s: :select],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        select: :boolean,
        pem: :string
      ]
    )
  end

  defp parse_and_check_any_releases(releases) do
    release_shas = parse_releases(releases)

    if Enum.empty?(release_shas) do
      {:error, ErrorMessage.not_found("no releases found")}
    else
      {:ok, release_shas}
    end
  end

  defp fetch_app_release_history(app_name, pem, opts) do
    Mix.shell().info([:yellow, "Fetching ", :bright, app_name, :reset, :yellow, " release history from elixir machines..."])

    DeployExHelpers.run_ssh_command_with_return(
      opts[:directory],
      pem,
      app_name,
      DeployEx.ReleaseController.list_releases()
    )
  end

  defp select_target_sha(release_shas, opts) do
    if opts[:select] do
      choice_map = Enum.into(release_shas, %{}, fn {timestamp, target_sha} ->
        timestamp = timestamp
          |> String.to_integer
          |> DateTime.from_unix!
          |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

        {"#{timestamp} - #{target_sha}", target_sha}
      end)

      choice = DeployExHelpers.prompt_for_choice(choice_map |> Map.keys |> Enum.reverse, false)

      Map.get(choice_map, choice)
    else
      release_shas |> List.first |> elem(1)
    end
  end

  def validate_target_sha_release_exists(releases, target_sha) do
    target_shas = releases |> parse_releases |> Enum.map(fn {_, target_sha} -> target_sha end)

    if Enum.member?(target_shas, target_sha) do
      {:ok, target_sha}
    else
      {:error, ErrorMessage.not_found("release not found")}
    end
  end

  defp parse_releases(releases) do
    releases
      |> Enum.join("\n")
      |> String.split("\n")
      |> Enum.map(&(&1 |> Path.basename |> String.split("-")))
      |> Enum.reject(&(&1 === [""] or is_nil(&1)))
      |> Enum.map(fn [timestamp, target_sha | _] -> {timestamp, target_sha} end)
  end
end
