defmodule Mix.Tasks.DeployEx.ExportPriv do
  use Mix.Task

  @shortdoc "Exports deploy_ex priv templates to ./deploys/ for local customization"
  @moduledoc """
  Copies Terraform, Ansible, and CI template files from the deploy_ex dependency
  into your project's deploy folder (default: `./deploys/`), enabling local
  customization. Once exported, tasks automatically read from `./deploys/`
  instead of the dependency.

  Run `mix deploy_ex.upgrade_priv` after upgrading deploy_ex to sync upstream
  changes while preserving your modifications.

  ## Example
  ```bash
  mix deploy_ex.export_priv
  mix deploy_ex.export_priv --force  # overwrite existing files
  ```

  ## Options
  - `force` - Overwrite files that already exist in `./deploys/` (alias: `f`)
  - `quiet` - Suppress output (alias: `q`)
  """

  def run(args) do
    opts = parse_args(args)
    deploy_folder = DeployEx.Config.deploy_folder()
    priv_dir = :deploy_ex |> :code.priv_dir() |> to_string()

    with :ok <- DeployExHelpers.check_in_umbrella() do
      File.mkdir_p!(deploy_folder)

      priv_files =
        priv_dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.reject(&File.dir?/1)
        |> Enum.reject(&String.ends_with?(&1, ".md"))

      manifest =
        Enum.reduce(priv_files, empty_manifest(), fn priv_path, acc ->
          relative_path = Path.relative_to(priv_path, priv_dir)
          dest_path = Path.join(deploy_folder, relative_path)
          content = File.read!(priv_path)
          hash = DeployEx.PrivManifest.hash_content(content)

          if File.exists?(dest_path) and not opts[:force] do
            Mix.shell().info([:yellow, "* skipping ", :reset, dest_path, " (exists, use --force to overwrite)"])
          else
            File.mkdir_p!(Path.dirname(dest_path))
            DeployExHelpers.write_file(dest_path, content, [{:message, [:green, "* copying ", :reset, dest_path]} | opts])
          end

          DeployEx.PrivManifest.put_file(acc, relative_path, hash)
        end)

      DeployEx.PrivManifest.write(deploy_folder, manifest)

      unless opts[:quiet] do
        Mix.shell().info([:green, "* manifest written to ", :reset, Path.join(deploy_folder, ".deploy_ex_manifest.exs")])
      end
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp empty_manifest do
    [
      deploy_ex_version: Application.spec(:deploy_ex, :vsn) |> to_string(),
      files: []
    ]
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet],
      switches: [force: :boolean, quiet: :boolean]
    )

    opts
  end
end
