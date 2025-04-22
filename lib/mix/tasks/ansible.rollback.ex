defmodule Mix.Tasks.Ansible.Rollback do
  use Mix.Task

  @ansible_default_path DeployEx.Config.ansible_folder_path()

  @shortdoc "Rollsback an ansible host to a previous sha"
  @moduledoc """
  Deploys a specific release from S3, if no sha is given chooses the last sha.

  This will load your target or release before last onto each node and sets it up
  in a SystemD task.

  ## Example
  ```bash
  mix ansible.rollback my_app
  mix ansible.rollback my_app --step 2
  mix ansible.rollback my_app --sha 2ac12b
  ```

  ## Options
  - `directory` - Directory containing ansible playbooks (default: #{@ansible_default_path})
  - `copy-json-env-file` - Copy environment file and load into host environments
  - `target-sha` - Target github sha
  - `quiet` - Suppress output messages
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, node_name_args} = parse_args(args)

      opts = opts
        |> Keyword.put_new(:directory, @ansible_default_path)
        |> Keyword.put_new(:aws_region, DeployEx.Config.aws_region())
        |> Keyword.put_new(:aws_release_bucket, DeployEx.Config.aws_release_bucket())

      with {:ok, app_name} <- DeployExHelpers.find_project_name(node_name_args),
           {:ok, releases} <- DeployEx.ReleaseUploader.fetch_all_remote_releases(opts),
           {:ok, latest_releases} <- DeployExHelpers.run_ssh_command(
             opts[:directory],
             opts[:pem],
             app_name,
             DeployEx.ReleaseController.list_releases()
           ),
           :ok <- check_any_releases(latest_releases),
           {:ok, target_sha} <- validate_target_sha_releaes_exists(releases, select_target_sha(latest_releases, opts)) do
        Mix.shell().info([
          :yellow, "Starting rollback to ", :bright, target_sha, :reset, :yellow, " for ", :bright, app_name, :reset
        ])

        with :ok <- Mix.Tasks.Ansible.Deploy.run(args <> "-t #{target_sha}") do
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

  defp check_any_releases(releases) do
    if Enum.empty?(releases) do
      {:error, ErrorMessage.not_found("no releases found")}
    else
      :ok
    end
  end

  defp select_target_sha(latest_releases, opts) do
    release_shas = latest_releases
      |> Enum.map(&(String.split(&1, "-")))
      |> Enum.map(fn [timestamp, target_sha | _] -> {timestamp, target_sha} end)
      |> Enum.uniq_by(fn {_timestamp, target_sha} -> target_sha end)

    select_target_release(release_shas, opts)
  end

  defp select_target_release(release_shas, opts) do
    if opts[:select] do
      choice_map = Enum.map(release_shas, fn {timestamp, target_sha} ->
        timestamp = timestamp |> DateTime.from_unix! |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

        {"#{timestamp} - #{target_sha}", target_sha}
      end)

      [choice] = DeployExHelpers.prompt_for_choice(Map.keys(choice_map), false)

      Map.get(choice_map, choice)
    else
      release_shas |> List.first |> elem(1)
    end
  end

  def validate_target_sha_releaes_exists(releases, target_sha) do
    if Enum.member?(releases, target_sha) do
      {:ok, target_sha}
    else
      {:error, ErrorMessage.not_found("release not found")}
    end
  end
end
