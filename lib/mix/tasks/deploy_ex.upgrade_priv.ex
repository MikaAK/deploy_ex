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
  mix deploy_ex.upgrade_priv --llm-merge  # attempt AI-assisted 3-way merge
  ```

  ## Options
  - `llm-merge` - Attempt LLM-assisted merge for modified files (requires `langchain` dep and `:llm_provider` config)
  """

  def run(args) do
    opts = parse_args(args)
    deploy_folder = DeployEx.Config.deploy_folder()
    priv_dir = :deploy_ex |> :code.priv_dir() |> to_string()

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, manifest} <- DeployEx.PrivManifest.read(deploy_folder) do
      priv_files =
        priv_dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.reject(&File.dir?/1)
        |> Enum.reject(&String.ends_with?(&1, ".md"))

      timestamp =
        DateTime.utc_now()
        |> DateTime.to_iso8601()
        |> String.replace(~r/[:\.]/, "-")

      backup_dir = Path.join([deploy_folder, ".backup", timestamp])

      {manifest, counts} =
        Enum.reduce(priv_files, {manifest, %{new: 0, auto_updated: 0, backed_up: 0}}, fn priv_path, {acc_manifest, acc_counts} ->
          relative_path = Path.relative_to(priv_path, priv_dir)
          dest_path = Path.join(deploy_folder, relative_path)
          upstream_content = File.read!(priv_path)
          upstream_hash = DeployEx.PrivManifest.hash_content(upstream_content)

          {updated_manifest, counts_key} =
            case DeployEx.PrivManifest.base_hash(acc_manifest, relative_path) do
              {:error, _} ->
                handle_new_file(dest_path, upstream_content, acc_manifest, relative_path, upstream_hash)

              {:ok, base_hash} ->
                user_content = if File.exists?(dest_path), do: File.read!(dest_path), else: upstream_content
                user_hash = DeployEx.PrivManifest.hash_content(user_content)

                if user_hash === base_hash do
                  handle_unmodified_file(dest_path, upstream_content, acc_manifest, relative_path, upstream_hash)
                else
                  handle_modified_file(dest_path, priv_path, backup_dir, relative_path, user_content, upstream_content, acc_manifest, upstream_hash, opts)
                end
            end

          {updated_manifest, Map.update!(acc_counts, counts_key, &(&1 + 1))}
        end)

      DeployEx.PrivManifest.write(deploy_folder, manifest)
      print_summary(counts, backup_dir)
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp handle_new_file(dest_path, upstream_content, manifest, relative_path, upstream_hash) do
    File.mkdir_p!(Path.dirname(dest_path))
    DeployExHelpers.write_file(dest_path, upstream_content, message: [:green, "* new ", :reset, dest_path], force: true)
    {DeployEx.PrivManifest.put_file(manifest, relative_path, upstream_hash), :new}
  end

  defp handle_unmodified_file(dest_path, upstream_content, manifest, relative_path, upstream_hash) do
    File.mkdir_p!(Path.dirname(dest_path))
    DeployExHelpers.write_file(dest_path, upstream_content, message: [:green, "* auto-updated ", :reset, dest_path], force: true)
    {DeployEx.PrivManifest.put_file(manifest, relative_path, upstream_hash), :auto_updated}
  end

  defp handle_modified_file(dest_path, priv_path, backup_dir, relative_path, user_content, upstream_content, manifest, upstream_hash, opts) do
    backup_path = Path.join(backup_dir, relative_path)
    File.mkdir_p!(Path.dirname(backup_path))
    File.write!(backup_path, user_content)

    Mix.shell().info([:yellow, "* backed up ", :reset, dest_path, :yellow, " -> ", :reset, backup_path])

    if opts[:llm_merge] do
      if Code.ensure_loaded?(DeployEx.LLMMerge) do
        case apply(DeployEx.LLMMerge, :merge, [nil, user_content, upstream_content]) do
          {:ok, merged} ->
            File.mkdir_p!(Path.dirname(dest_path))
            DeployExHelpers.write_file(dest_path, merged, message: [:green, "* llm-merged ", :reset, dest_path], force: true)

          {:error, _reason} ->
            File.mkdir_p!(Path.dirname(dest_path))
            DeployExHelpers.write_file(dest_path, upstream_content, message: [:yellow, "* overwritten (llm merge failed) ", :reset, dest_path], force: true)
            print_diff(backup_path, priv_path)
        end
      else
        Mix.shell().info([:red, "* --llm-merge requires the langchain dependency. Add {:langchain, \"~> 0.6\"} to your deps."])
        File.mkdir_p!(Path.dirname(dest_path))
        DeployExHelpers.write_file(dest_path, upstream_content, message: [:yellow, "* overwritten ", :reset, dest_path], force: true)
        print_diff(backup_path, priv_path)
      end
    else
      File.mkdir_p!(Path.dirname(dest_path))
      DeployExHelpers.write_file(dest_path, upstream_content, message: [:yellow, "* overwritten ", :reset, dest_path], force: true)
      print_diff(backup_path, priv_path)
    end

    {DeployEx.PrivManifest.put_file(manifest, relative_path, upstream_hash), :backed_up}
  end

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

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      switches: [llm_merge: :boolean]
    )

    opts
  end
end
