defmodule Mix.Tasks.DeployEx.Release do
  use Mix.Task

  alias DeployEx.{ReleaseUploader, Config}

  @default_aws_region Config.aws_region()
  @default_aws_release_bucket Config.aws_release_bucket()

  @shortdoc "Builds releases for applications with detected changes"
  @moduledoc """
  Intelligently builds releases for applications that have changes since their last release.

  The task performs the following:
  1. Checks AWS S3 for existing releases
  2. Compares git changes between current branch and last release
  3. Builds new releases if changes are detected in:
     - Application code
     - Umbrella dependency code
     - mix.lock dependencies
  4. Automatically runs `mix assets.deploy` for Phoenix applications

  ## Example
  ```bash
  # Build releases for all changed apps
  mix deploy_ex.release

  # Force rebuild specific apps
  mix deploy_ex.release --only app1 --only app2 --force

  # Build all except certain apps
  mix deploy_ex.release --except app3
  ```

  ## Options
  - `force` - Force rebuild releases even without changes (alias: `f`)
  - `quiet` - Suppress output messages (alias: `q`)
  - `only` - Only build releases for specified apps (can be used multiple times)
  - `except` - Skip building releases for specified apps (can be used multiple times)
  - `recompile` - Force recompilation before release (alias: `r`)
  - `aws-region` - AWS region for S3 storage (default: `#{@default_aws_region}`)
  - `aws-bucket` - S3 bucket for storing releases (default: `#{@default_aws_release_bucket}`)
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)

    opts = args
      |> parse_args
      |> Keyword.put_new(:aws_release_bucket, @default_aws_release_bucket)
      |> Keyword.put_new(:aws_region, @default_aws_region)

    opts = opts
      |> Keyword.put(:only, Keyword.get_values(opts, :only))
      |> Keyword.put(:except, Keyword.get_values(opts, :except))
      |> Keyword.put(:qa_release, qa_release?())

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
      |> DeployExHelpers.filter_only_or_except(opts[:only], opts[:except])
      |> ReleaseUploader.build_state(remote_releases, git_sha, opts)
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
        aws_release_bucket: :string,
        only: :keep,
        except: :keep,
        all: :boolean
      ]
    )

    opts
  end

  defp qa_release? do
    qa_branch?(git_branch_name())
  end

  defp git_branch_name do
    case ReleaseUploader.get_git_branch() do
      {:ok, branch_name} -> branch_name
      {:error, _} -> nil
    end
  end

  defp qa_branch?(branch_name) when is_binary(branch_name) do
    String.starts_with?(branch_name, "qa/") or String.starts_with?(branch_name, "qa-")
  end

  defp qa_branch?(_branch_name), do: false

  defp split_releases_and_run_release_commands(release_states, opts) do
    with {
      :ok,
      app_type_release_state_tuples
    } <- filter_changed_releases_and_mark_release_type(release_states, opts) do
      {has_previous_upload_release_cands, no_prio_upload_release_cands} = Enum.split_with(
        app_type_release_state_tuples,
        fn {_app_type, %ReleaseUploader.State{last_sha: last_sha}} -> last_sha end
      )

      if Enum.any?(has_previous_upload_release_cands) or Enum.any?(no_prio_upload_release_cands)  do
        with {:ok, initial_releases} <- run_initial_release(no_prio_upload_release_cands, opts),
             {:ok, update_releases} <- run_update_releases(has_previous_upload_release_cands, opts) do
          Mix.shell().info([
            :green, "Successfuly built ",
            :reset, Enum.map_join(initial_releases ++ update_releases, ", ", &(&1.app_name))
          ])

          :ok
        else
          {:error, [h | tail]} ->
            Enum.each(tail, &Mix.shell().error("Error with releasing #{inspect(&1, pretty: true)}"))

            Mix.raise(inspect(h, pretty: true))
        end
      else
        if Enum.empty?(release_states) do
          Mix.shell().info([:yellow, "No new changes found for releases"])
        else
          Mix.shell().info([
            :yellow, "No new changes found for ",
            :reset, Enum.map_join(release_states, ", ", &(&1.app_name))
          ])
        end
      end
    end
  end

  defp filter_changed_releases_and_mark_release_type(release_states, opts) do
    with {:ok, app_dep_tree} <- ReleaseUploader.app_dep_tree() do
      if opts[:all] do
        {:ok, Enum.map(
          release_states,
          &create_app_type_release_state_tuple(&1, app_dep_tree)
        )}
      else
        with {:ok, release_states} <- ReleaseUploader.filter_changed_releases(release_states) do
          {:ok, Enum.map(
            release_states,
            &create_app_type_release_state_tuple(&1, app_dep_tree)
          )}
        end
      end
    end
  end

  defp create_app_type_release_state_tuple(%ReleaseUploader.State{} = release_state, app_dep_tree) do
    deps_in_release_app = Enum.flat_map(release_state.release_apps, &(app_dep_tree[&1]))

    if "phoenix" in deps_in_release_app do
      {:phoenix, release_state}
    else
      {:normal, release_state}
    end
  end

  defp run_initial_release(release_candidates, opts) do
    release_candidates
      |> Enum.map(fn {app_type, %ReleaseUploader.State{} = candidate} ->
        Mix.shell().info([
          :green, "* running initial release for ",
          :reset, candidate.local_file
        ])

        run_app_type_pre_release(app_type, candidate)
        run_mix_release(candidate, opts)
      end)
      |> DeployEx.Utils.reduce_status_tuples
  end

  defp run_update_releases(release_candidates, opts) do
    release_candidates
      |> Enum.map(fn {app_type, %ReleaseUploader.State{} = candidate} ->
        Mix.shell().info([
          :green, "* running release to update ",
          :reset, candidate.local_file
        ])

        run_app_type_pre_release(app_type, candidate)
        run_mix_release(candidate, opts)
      end)
      |> DeployEx.Utils.reduce_status_tuples
  end

  defp run_app_type_pre_release(:phoenix, candidate) do
    app_path = Mix.Project.apps_paths()[String.to_atom(candidate.app_name)]
    package_json_path = Path.join(app_path, "assets/package.json")

    has_package_lock? = File.exists?(package_json_path)

    if has_package_lock? do
      assets_path = Path.dirname(package_json_path)
      Mix.shell().info([
        :green, "* running ",
        :reset, "npm install ", :green, "for ",
        :reset, candidate.app_name, :green, " in ",
        :reset, assets_path
      ])

      case System.shell("npm i", cd: assets_path, into: IO.stream()) do
        {_, 0} ->  :ok
        {output, code} -> Mix.raise("Error running npm i #{code}\n#{inspect(output, pretty: true)}")
      end
    end

    run_phoenix_asset_pipeline(candidate.app_name)

    :ok
  end

  defp run_app_type_pre_release(:normal, _candidate) do
    nil
  end

  defp run_phoenix_asset_pipeline(app_name) do
    app_name_atom = String.to_atom(app_name)
    app_path = Mix.Project.apps_paths()[app_name_atom]

    with {:ok, js_files} <- app_path |> Path.join("./assets/js") |> File.ls do
      if Enum.any?(js_files) do
        Mix.shell().info([
          :green, "* running ", :reset, "esbuild",
          :green, " for ", :reset, app_name
        ])

        Mix.Task.run("do", ["--app", app_name, "mix", "esbuild", build_config_name(:esbuild, app_name_atom), "--minify"])
      end
    end

    with {:ok, css_files} <- app_path |> Path.join("./assets/css") |> File.ls do
      if css_files |> Enum.filter(&(&1 =~ ~r/\.s(a|c)ss$/)) |> Enum.any? do
        Mix.shell().info([
          :green, "* running ", :reset, "sass",
          :green, " for ", :reset, app_name
        ])

        Mix.Task.run("do", ["--app", app_name, "mix", "sass", build_config_name(:dart_sass, app_name_atom)])
      end
    end

    if app_path |> Path.join("./assets/tailwind.config.js") |> File.exists? do
      Mix.shell().info([
        :green, "* running ", :reset, "tailwind",
        :green, " for ", :reset, app_name
      ])

      Mix.Task.run("do", ["--app", app_name, "mix", "tailwind", build_config_name(:tailwind, app_name_atom), "--minify"])
    end

    Mix.shell().info([
      :green, "* running ", :reset, "phoenix digest",
      :green, " for ", :reset, app_name
    ])

    Mix.Task.run("do", ["--app", app_name, "mix", "phx.digest"])
  end

  defp build_config_name(build_app, app_name) do
    if Application.get_env(build_app, app_name) do
      to_string(app_name)
    else
      "default"
    end
  end

  defp run_mix_release(%ReleaseUploader.State{app_name: app_name} = candidate, opts) do
    args = Enum.reduce(opts, [], fn
      {:force, true}, acc -> ["--overwrite" | acc]
      {:recompile, true}, acc -> ["--force" | acc]
      {:quiet, true}, acc -> ["--quiet" | acc]
      _, acc -> acc
    end)

    Mix.Task.clear()
    case Mix.Task.run("release", [app_name | args]) do
      :ok -> {:ok, candidate}
      :noop -> {:ok, candidate}
      {:error, reason} -> {:ok, ErrorMessage.failed_dependency("mix release failed", %{reason: reason})}
    end
  end
end
