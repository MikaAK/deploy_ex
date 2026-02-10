defmodule Mix.Tasks.DeployEx.Qa.Deploy do
  use Mix.Task

  @shortdoc "Deploys a specific SHA to an existing QA node"
  @moduledoc """
  Deploys a specific SHA to an existing QA node.

  ## Example
  ```bash
  mix deploy_ex.qa.deploy my_app --sha def5678
  ```

  ## Options
  - `--sha, -s` - Target git SHA (required)
  - `--quiet, -q` - Suppress output messages
  - `--aws-region` - AWS region (default: from config)
  - `--aws-release-bucket` - S3 bucket for releases (default: from config)
  """

  @ansible_default_path DeployEx.Config.ansible_folder_path()

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- DeployExHelpers.ensure_ansible_installed() do
      {opts, extra_args} = parse_args(args)

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required. Usage: mix deploy_ex.qa.deploy <app_name> --sha <sha>")
      end

      sha = opts[:sha] || Mix.raise("--sha option is required")

      with {:ok, qa_node} <- fetch_and_verify_qa_node(app_name, opts),
           {:ok, full_sha} <- validate_and_find_sha(app_name, sha, opts),
           :ok <- run_ansible_deploy(qa_node, full_sha, opts),
           {:ok, _updated} <- update_qa_state_sha(qa_node, full_sha, opts) do
        unless opts[:quiet] do
          Mix.shell().info([
            :green, "\n✓ Deployed SHA ", :cyan, String.slice(full_sha, 0, 7),
            :green, " to QA node ", :cyan, qa_node.instance_name, :reset
          ])
        end
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :sha, q: :quiet],
      switches: [
        sha: :string,
        quiet: :boolean,
        aws_region: :string,
        aws_release_bucket: :string
      ]
    )
  end

  defp fetch_and_verify_qa_node(app_name, opts) do
    case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
      {:ok, nil} ->
        {:error, ErrorMessage.not_found("no QA node found for app '#{app_name}'")}

      {:ok, qa_node} ->
        DeployEx.QaNode.verify_instance_exists(qa_node)

      error ->
        error
    end
  end

  defp validate_and_find_sha(app_name, sha, opts) do
    fetch_opts = [
      aws_release_bucket: opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket(),
      aws_region: opts[:aws_region] || DeployEx.Config.aws_region()
    ]

    case DeployEx.ReleaseUploader.fetch_all_remote_releases(fetch_opts) do
      {:ok, releases} ->
        {qa_match, qa_releases} = find_release_match(releases, app_name, sha, "qa")

        {matching_release, candidate_releases} = if is_nil(qa_match) do
            {fallback_match, fallback_releases} = find_release_match(releases, app_name, sha, nil)
            {fallback_match, qa_releases ++ fallback_releases}
          else
            {qa_match, qa_releases}
          end

        if is_nil(matching_release) do
          suggestions = DeployExHelpers.format_release_suggestions(candidate_releases, sha)
          {:error, ErrorMessage.not_found("no release found matching SHA '#{sha}' for app '#{app_name}'", %{suggestions: suggestions})}
        else
          full_sha = DeployExHelpers.extract_sha_from_release(matching_release)

          if is_nil(full_sha) do
            {:error, ErrorMessage.bad_request("couldn't extract SHA from release name")}
          else
            {:ok, full_sha}
          end
        end

      {:error, _} = error ->
        error
    end
  end


  defp run_ansible_deploy(qa_node, sha, opts) do
    unless opts[:quiet] do
      Mix.shell().info("Deploying SHA #{String.slice(sha, 0, 7)} to #{qa_node.instance_name}...")
    end

    directory = @ansible_default_path
    playbook = "playbooks/#{qa_node.app_name}.yaml"

    command = "ansible-playbook #{playbook} --limit '#{qa_node.instance_name},' --extra-vars 'target_release_sha=#{sha} release_prefix=qa release_state_prefix=release-state/qa'"

    case DeployEx.Utils.run_command(command, directory) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, ErrorMessage.failed_dependency("ansible deploy failed", %{error: error})}
    end
  end

  defp find_release_match(releases, app_name, sha, release_prefix) do
    path_prefix = release_path_prefix(app_name, release_prefix)
    app_releases = Enum.filter(releases, &String.starts_with?(&1, path_prefix))
    matching = Enum.find(app_releases, &String.contains?(&1, sha))

    {matching, app_releases}
  end

  defp release_path_prefix(app_name, nil), do: "#{app_name}/"
  defp release_path_prefix(app_name, ""), do: "#{app_name}/"
  defp release_path_prefix(app_name, release_prefix), do: "#{release_prefix}/#{app_name}/"

  defp update_qa_state_sha(qa_node, sha, opts) do
    updated = %{qa_node | target_sha: sha}

    case DeployEx.QaNode.save_qa_state(updated, opts) do
      {:ok, :saved} -> {:ok, updated}
      error -> error
    end
  end
end
