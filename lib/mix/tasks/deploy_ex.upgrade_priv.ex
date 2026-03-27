defmodule Mix.Tasks.DeployEx.UpgradePriv do
  use Mix.Task

  @shortdoc "Upgrades ./deploys/ templates from the latest deploy_ex dependency"
  @moduledoc """
  Syncs Terraform, Ansible, and CI template files in `./deploys/` from the
  latest version of the deploy_ex dependency.

  Files are categorized as:
  - **New**: copied automatically (no previous version)
  - **Unmodified**: overwritten silently (you never changed them)
  - **Modified**: your version is backed up, upstream overwrites, diff is shown

  Requires `mix deploy_ex.export_priv` to have been run first.

  ## Example
  ```bash
  mix deploy_ex.upgrade_priv
  mix deploy_ex.upgrade_priv --llm-merge
  ```

  ## Options
  - `llm-merge` - Use LLM to plan the merge autonomously, detecting renames and
    restructuring, then merge file contents for conflicts. Requires `langchain`
    dep and `:llm_provider` config.
  """

  def run(args) do
    opts = parse_args(args)
    deploy_folder = DeployEx.Config.deploy_folder()
    priv_dir = :deploy_ex |> :code.priv_dir() |> to_string()

    with :ok <- DeployExHelpers.check_valid_project() do
      priv_files = list_priv_files(priv_dir)
      manifest = load_or_generate_manifest(deploy_folder)

      timestamp =
        DateTime.utc_now()
        |> DateTime.to_iso8601()
        |> String.replace(~r/[:\.]/, "-")

      backup_dir = Path.join([deploy_folder, ".backup", timestamp])

      if opts[:llm_merge] do
        run_llm_upgrade(priv_files, priv_dir, deploy_folder, manifest, backup_dir)
      else
        run_standard_upgrade(priv_files, priv_dir, deploy_folder, manifest, backup_dir)
      end
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  # SECTION: Standard Upgrade (no LLM)

  defp run_standard_upgrade(priv_files, priv_dir, deploy_folder, manifest, backup_dir) do
    {manifest, counts} =
      Enum.reduce(
        priv_files,
        {manifest, %{new: 0, auto_updated: 0, backed_up: 0}},
        fn priv_path, {acc_manifest, acc_counts} ->
          relative_path = Path.relative_to(priv_path, priv_dir)
          dest_path = Path.join(deploy_folder, relative_path)
          upstream_content = File.read!(priv_path)
          upstream_hash = DeployEx.PrivManifest.hash_content(upstream_content)

          {updated_manifest, counts_key} =
            case DeployEx.PrivManifest.base_hash(acc_manifest, relative_path) do
              {:error, _} ->
                write_new_file(dest_path, upstream_content, acc_manifest, relative_path, upstream_hash)

              {:ok, base_hash} ->
                user_content =
                  if File.exists?(dest_path), do: File.read!(dest_path), else: upstream_content

                user_hash = DeployEx.PrivManifest.hash_content(user_content)

                if user_hash === base_hash do
                  write_unmodified_file(dest_path, upstream_content, acc_manifest, relative_path, upstream_hash)
                else
                  backup_and_overwrite(
                    dest_path, priv_path, backup_dir, relative_path,
                    user_content, upstream_content, acc_manifest, upstream_hash
                  )
                end
            end

          {updated_manifest, Map.update!(acc_counts, counts_key, &(&1 + 1))}
        end
      )

    DeployEx.PrivManifest.write(deploy_folder, manifest)
    print_summary(counts, backup_dir)
  end

  # SECTION: LLM Upgrade (plan + execute)

  defp run_llm_upgrade(priv_files, priv_dir, deploy_folder, manifest, backup_dir) do
    upstream_paths = Enum.map(priv_files, &Path.relative_to(&1, priv_dir))

    user_paths =
      deploy_folder
      |> list_deploy_files()
      |> Enum.map(&Path.relative_to(&1, deploy_folder))

    upstream_only = upstream_paths -- user_paths
    user_only = user_paths -- upstream_paths
    shared = upstream_paths -- upstream_only

    # For shared paths, check which are actually different
    {identical, changed} =
      Enum.split_with(shared, fn path ->
        upstream_content = File.read!(Path.join(priv_dir, path))
        user_content = File.read!(Path.join(deploy_folder, path))
        upstream_content === user_content
      end)

    change_manifest = %{
      new_upstream: upstream_only,
      modified: changed,
      user_only: user_only
    }

    Mix.shell().info([:cyan, "* planning merge with LLM..."])
    Mix.shell().info("  #{length(upstream_only)} new upstream, #{length(changed)} changed, #{length(identical)} identical, #{length(user_only)} user-only")

    case DeployEx.LLMMerge.plan(change_manifest) do
      {:ok, actions} ->
        Mix.shell().info([:green, "* LLM produced #{length(actions)} action(s)"])
        manifest = execute_plan(actions, priv_dir, deploy_folder, manifest, backup_dir)
        DeployEx.PrivManifest.write(deploy_folder, manifest)

        print_summary(
          %{
            new: Enum.count(actions, &match?({:copy_upstream, _}, &1)),
            auto_updated: length(identical),
            backed_up: Enum.count(actions, &match?({:merge, _, _}, &1))
          },
          backup_dir
        )

      {:error, reason} ->
        Mix.shell().info([
          :yellow,
          "* LLM planning failed (#{inspect(reason)}), falling back to standard upgrade"
        ])

        run_standard_upgrade(priv_files, priv_dir, deploy_folder, manifest, backup_dir)
    end
  end

  defp execute_plan(actions, priv_dir, deploy_folder, manifest, backup_dir) do
    context = %{deploy_folder: deploy_folder, priv_dir: priv_dir}

    Enum.reduce(actions, manifest, fn action, acc_manifest ->
      case action do
        {:copy_upstream, upstream_path} ->
          dest_path = Path.join(deploy_folder, upstream_path)
          upstream_content = File.read!(Path.join(priv_dir, upstream_path))
          upstream_hash = DeployEx.PrivManifest.hash_content(upstream_content)
          {updated, _} = write_new_file(dest_path, upstream_content, acc_manifest, upstream_path, upstream_hash)
          updated

        {:merge, upstream_path, user_path} ->
          dest_path = Path.join(deploy_folder, user_path)
          user_content = File.read!(dest_path)
          upstream_content = File.read!(Path.join(priv_dir, upstream_path))
          upstream_hash = DeployEx.PrivManifest.hash_content(upstream_content)

          backup_path = Path.join(backup_dir, user_path)
          File.mkdir_p!(Path.dirname(backup_path))
          File.write!(backup_path, user_content)
          Mix.shell().info([:yellow, "* backed up ", :reset, dest_path, :yellow, " -> ", :reset, backup_path])

          case DeployEx.LLMMerge.execute_merge(action, context) do
            {:ok, merged} ->
              File.mkdir_p!(Path.dirname(dest_path))

              DeployExHelpers.write_file(dest_path, merged,
                message: [:green, "* llm-merged ", :reset, dest_path],
                force: true
              )

            {:error, reason} ->
              Mix.shell().info([:yellow, "* file merge failed (#{inspect(reason)}), overwriting"])

              File.mkdir_p!(Path.dirname(dest_path))

              DeployExHelpers.write_file(dest_path, upstream_content,
                message: [:yellow, "* overwritten ", :reset, dest_path],
                force: true
              )

            :skip ->
              :ok
          end

          DeployEx.PrivManifest.put_file(acc_manifest, upstream_path, upstream_hash)

        {:keep_user, _user_path} ->
          acc_manifest
      end
    end)
  end

  # SECTION: File Operations

  defp write_new_file(dest_path, upstream_content, manifest, relative_path, upstream_hash) do
    File.mkdir_p!(Path.dirname(dest_path))

    DeployExHelpers.write_file(dest_path, upstream_content,
      message: [:green, "* new ", :reset, dest_path],
      force: true
    )

    {DeployEx.PrivManifest.put_file(manifest, relative_path, upstream_hash), :new}
  end

  defp write_unmodified_file(dest_path, upstream_content, manifest, relative_path, upstream_hash) do
    File.mkdir_p!(Path.dirname(dest_path))

    DeployExHelpers.write_file(dest_path, upstream_content,
      message: [:green, "* auto-updated ", :reset, dest_path],
      force: true
    )

    {DeployEx.PrivManifest.put_file(manifest, relative_path, upstream_hash), :auto_updated}
  end

  defp backup_and_overwrite(
         dest_path, priv_path, backup_dir, relative_path,
         user_content, upstream_content, manifest, upstream_hash
       ) do
    backup_path = Path.join(backup_dir, relative_path)
    File.mkdir_p!(Path.dirname(backup_path))
    File.write!(backup_path, user_content)

    Mix.shell().info([
      :yellow, "* backed up ", :reset, dest_path,
      :yellow, " -> ", :reset, backup_path
    ])

    File.mkdir_p!(Path.dirname(dest_path))

    DeployExHelpers.write_file(dest_path, upstream_content,
      message: [:yellow, "* overwritten ", :reset, dest_path],
      force: true
    )

    print_diff(backup_path, priv_path)

    {DeployEx.PrivManifest.put_file(manifest, relative_path, upstream_hash), :backed_up}
  end

  # SECTION: Output

  defp print_diff(old_path, new_path) do
    case System.cmd("diff", [old_path, new_path], stderr_to_stdout: true) do
      {output, _exit_code} when output !== "" ->
        Mix.shell().info([:cyan, "--- diff (your backup vs upstream) ---"])
        Mix.shell().info(output)
        Mix.shell().info([:cyan, "--------------------------------------"])

      _ ->
        :ok
    end
  end

  defp print_summary(counts, backup_dir) do
    Mix.shell().info("")
    Mix.shell().info([:green, "Upgrade complete:"])
    Mix.shell().info("  #{counts.new} new file(s) added")
    Mix.shell().info("  #{counts.auto_updated} file(s) auto-updated (unmodified)")
    Mix.shell().info("  #{counts.backed_up} file(s) backed up and overwritten")

    if counts.backed_up > 0 do
      Mix.shell().info([:yellow, "\nReview the diffs above. Your backups are in: #{backup_dir}"])
    end
  end

  # SECTION: Manifest

  defp load_or_generate_manifest(deploy_folder) do
    case DeployEx.PrivManifest.read(deploy_folder) do
      {:ok, manifest} ->
        manifest

      {:error, _} ->
        if File.exists?(deploy_folder) do
          Mix.shell().info([:yellow, "* no manifest found, generating from existing files in #{deploy_folder}"])
          generate_manifest_from_existing(deploy_folder)
        else
          [deploy_ex_version: to_string(Application.spec(:deploy_ex, :vsn)), files: []]
        end
    end
  end

  defp generate_manifest_from_existing(deploy_folder) do
    deploy_folder
    |> list_deploy_files()
    |> Enum.reduce(
      [deploy_ex_version: to_string(Application.spec(:deploy_ex, :vsn)), files: []],
      fn file_path, acc ->
        relative_path = Path.relative_to(file_path, deploy_folder)
        hash = file_path |> File.read!() |> DeployEx.PrivManifest.hash_content()
        DeployEx.PrivManifest.put_file(acc, relative_path, hash)
      end
    )
  end

  defp list_deploy_files(deploy_folder) do
    deploy_folder
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.reject(&String.ends_with?(&1, ".md"))
    |> Enum.reject(&String.starts_with?(Path.relative_to(&1, deploy_folder), "."))
  end

  # SECTION: Helpers

  defp list_priv_files(priv_dir) do
    priv_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.reject(&String.ends_with?(&1, ".md"))
  end

  defp parse_args(args) do
    {opts, _} =
      OptionParser.parse!(args,
        switches: [llm_merge: :boolean]
      )

    opts
  end
end
