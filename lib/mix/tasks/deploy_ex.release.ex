defmodule Mix.Tasks.DeployEx.Release do
  use Mix.Task

  alias DeployEx.{ReleaseUploader, Config}

  @default_aws_region Config.aws_release_region()
  @default_aws_bucket Config.aws_release_bucket()
  @max_build_concurrency 6
  @release_timeout :timer.minutes(10)

  @shortdoc "Runs mix.release for apps that have changed"
  @moduledoc """
  This command checks AWS S3 for the current releases and checks
  if there are any changes in git between the current branch and
  current release. If there are changes in direct app code,
  inner umbrella dependency code changes or dep changes in the mix.lock
  that are connected to your app, the release will run, otherwise it will
  ignore it

  This command also correctly detects phoenix applications, and if found will
  run `mix assets.deploy` in those apps

  ## Options

  - `force` - Force overwrite (alias: `f`)
  - `quiet` - Force overwrite (alias: `q`)
  - `recompile` - Force recompile (alias: `r`)
  - `aws-region` - Region for aws (default: `#{@default_aws_region}`)
  - `aws-bucket` - Region for aws (default: `#{@default_aws_bucket}`)
  - `parallel` - Set max amount of releases running at once
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)

    opts = args
      |> parse_args
      |> Keyword.put_new(:aws_bucket, Config.aws_release_bucket())
      |> Keyword.put_new(:aws_region, Config.aws_release_region())
      |> Keyword.put_new(:parallel, @max_build_concurrency)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         {:ok, remote_releases} <- ReleaseUploader.fetch_all_remote_releases(opts),
         {:ok, git_sha} <- ReleaseUploader.get_git_sha(),
         :ok <- build_state_and_upload_unchanged_releases(
           releases, remote_releases,
           git_sha, opts
         ) do
      :ok
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp build_state_and_upload_unchanged_releases(releases, remote_releases, git_sha, opts) do
    releases
      |> Keyword.keys
      |> Enum.map(&to_string/1)
      |> ReleaseUploader.build_state(remote_releases, git_sha)
      |> Enum.reject(&Mix.Tasks.DeployEx.Upload.already_uploaded?/1)
      |> split_releases_and_run_release_commands(opts)
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, r: :recompile],
      switches: [
        force: :boolean,
        quiet: :boolean,
        recompile: :boolean,
        aws_region: :string,
        aws_bucket: :string,
        parallel: :integer
      ]
    )

    opts
  end


  defp split_releases_and_run_release_commands(release_states, opts) do
    with {
      :ok,
      app_type_release_state_tuples
    } <- reject_unchanged_releases_and_mark_release_type(release_states) do
      {has_previous_upload_release_cands, no_prio_upload_release_cands} = Enum.split_with(
        app_type_release_state_tuples,
        fn {_app_type, %ReleaseUploader.State{last_sha: last_sha}} -> last_sha end
      )

      if Enum.any?(has_previous_upload_release_cands) or Enum.any?(no_prio_upload_release_cands)  do
        tasks = [
          Task.async(fn -> run_initial_release(no_prio_upload_release_cands, opts) end),
          Task.async(fn -> run_update_releases(has_previous_upload_release_cands, opts) end)
        ]

        res = tasks
          |> Enum.map(&Task.await(&1, :timer.seconds(60)))
          |> DeployEx.Utils.reduce_status_tuples

        case res do
          {:error, [h | tail]} ->
            Enum.each(tail, &Mix.shell().error("Error with releasing #{inspect(&1, pretty: true)}"))

            Mix.raise(inspect(h, pretty: true))

          {:ok, _} ->
            Mix.shell().info([
              :green, "Successfuly built ",
              :reset, Enum.map_join(app_type_release_state_tuples, ", ", &elem(&1, 1).app_name)
            ])

            :ok
        end
      else
        Mix.shell().info([
          :yellow, "No new changes found for ",
          :reset, Enum.map_join(release_states, ", ", &(&1.app_name))
        ])
      end
    end
  end

  defp reject_unchanged_releases_and_mark_release_type(release_states) do
    with {:ok, release_states} <- ReleaseUploader.reject_unchanged_releases(release_states),
         {:ok, app_dep_tree} <- ReleaseUploader.app_dep_tree() do
      {:ok, Enum.map(release_states, &create_app_type_release_state_tuple(&1, app_dep_tree))}
    else
      {:error, e} ->
        Mix.shell().error(to_string(e))

        {:ok, []}
    end
  end

  defp create_app_type_release_state_tuple(%ReleaseUploader.State{} = release_state, app_dep_tree) do
    if "phoenix" in app_dep_tree[release_state.app_name] do
      {:phoenix, release_state}
    else
      {:normal, release_state}
    end
  end

  defp run_initial_release(release_candidates, opts) do
    release_candidates
      |> Task.async_stream(fn {app_type, %ReleaseUploader.State{} = candidate} ->
        Mix.shell().info([
          :green, "* running initial release for ",
          :reset, candidate.local_file
        ])

        run_app_type_pre_release(app_type, candidate)
        run_mix_release(candidate, opts)
      end, timeout: @release_timeout, max_concurrency: div(opts[:parallel], 2))
      |> DeployEx.Utils.reduce_task_status_tuples
  end

  defp run_update_releases(release_candidates, opts) do
    release_candidates
      |> Task.async_stream(fn {app_type, %ReleaseUploader.State{} = candidate} ->
        Mix.shell().info([
          :green, "* running release to update ",
          :reset, candidate.local_file
        ])

        run_app_type_pre_release(app_type, candidate)
        run_mix_release(candidate, opts)
      end, timeout: @release_timeout, max_concurrency: div(opts[:parallel], 2))
      |> DeployEx.Utils.reduce_task_status_tuples
  end

  defp run_app_type_pre_release(:phoenix, candidate) do
    app_path = Mix.Project.apps_paths()[String.to_atom(candidate.app_name)]
    package_json_path = Path.join(app_path, "assets/package.json")

    has_package_lock? = File.exists?(package_json_path)
    has_static_files? = has_package_lock? or (app_path |> Path.join("./priv/static") |> File.exists?)

    cond do
      has_package_lock? ->
        Mix.shell().info([
          :green, "* running ", :reset, "npm install",
          :green, " for ", :reset, candidate.app_name
        ])

        case System.shell("npm i", cd: Path.dirname(package_json_path), into: IO.stream()) do
          {_, 0} ->  :ok
          {output, code} -> Mix.raise("Error running npm i #{code}\n#{inspect(output, pretty: true)}")
        end

        run_phoenix_asset_pipeline(candidate.app_name)

      has_static_files? ->
        Mix.Task.run(Mix.Tasks.Phx.Digest, [])

      true -> :ok
    end
  end

  defp run_app_type_pre_release(:normal, _candidate) do
    nil
  end

  defp run_phoenix_asset_pipeline(app_name) do
    Mix.shell().info([
      :green, "* running ", :reset, "esbuild",
      :green, " for ", :reset, app_name
    ])

    Mix.Task.run("cmd", ["--app", app_name, "mix", "esbuild", "default", "--minify"])

    Mix.shell().info([
      :green, "* running ", :reset, "sass",
      :green, " for ", :reset, app_name
    ])

    Mix.Task.run("cmd", ["--app", app_name, "mix", "sass", "default"])

    Mix.shell().info([
      :green, "* running ", :reset, "tailwind",
      :green, " for ", :reset, app_name
    ])

    Mix.Task.run("cmd", ["--app", app_name, "mix", "tailwind", "default", "--minify"])

    Mix.shell().info([
      :green, "* running ", :reset, "phoenix digest",
      :green, " for ", :reset, app_name
    ])

    Mix.Task.run("cmd", ["--app", app_name, "mix", "phx.digest"])
  end

  defp run_mix_release(%ReleaseUploader.State{app_name: app_name} = candidate, opts) do
    args = Enum.reduce(opts, [], fn
      {:force, true}, acc -> ["--overwrite" | acc]
      {:recompile, true}, acc -> ["--force" | acc]
      {:quiet, true}, acc -> ["--quiet" | acc]
      _, acc -> acc
    end)

    case Mix.Tasks.Release.run([app_name | args]) do
      :ok -> {:ok, candidate}
      {:error, reason} -> {:ok, ErrorMessage.failed_dependency("mix release failed", %{reason: reason})}
    end
  end
end


