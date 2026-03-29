defmodule Mix.Tasks.DeployEx.ExportPriv do
  use Mix.Task

  @shortdoc "Exports rendered deploy_ex templates to ./deploys/ for local customization"
  @moduledoc """
  Switches from internal mode (templates served from the deploy_ex dependency)
  to user-managed mode (templates in `./deploys/` that you own and customize).

  This renders all Terraform and Ansible templates with your project's configuration
  (release names, AWS settings, feature flags) and copies the output to `./deploys/`.
  From this point, build tasks read from `./deploys/` instead of the dependency.

  Use `mix deploy_ex.upgrade_priv` after upgrading deploy_ex to merge upstream
  changes into your customized files.

  ## Example

      mix deploy_ex.export_priv
      mix deploy_ex.export_priv --force  # overwrite existing files

  ## Options

  - `force` - Overwrite files that already exist in `./deploys/` (alias: `f`)
  - `quiet` - Suppress output (alias: `q`)
  """

  # SECTION: Public API

  @spec run(list(String.t())) :: :ok
  def run(args) do
    opts = parse_args(args)
    deploy_folder = DeployEx.Config.deploy_folder()

    with :ok <- DeployExHelpers.check_valid_project() do
      if File.exists?(deploy_folder) and not opts[:force] do
        Mix.shell().info([
          :yellow, "#{deploy_folder} already exists. ",
          :reset, "Use --force to overwrite, or run mix deploy_ex.upgrade_priv to merge changes."
        ])
      else
        run_export(deploy_folder, opts)
      end
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  # SECTION: Private

  defp run_export(deploy_folder, opts) do
    unless opts[:quiet] do
      Mix.shell().info([:cyan, "Rendering templates..."])
    end

    case DeployEx.PrivRenderer.render_to_temp(opts) do
      {:ok, temp_dir} ->
        copy_rendered_to_deploy(temp_dir, deploy_folder, opts)
        write_manifest(temp_dir, deploy_folder)
        File.rm_rf!(temp_dir)

        unless opts[:quiet] do
          Mix.shell().info([:green, "Exported to #{deploy_folder}"])
          Mix.shell().info("Templates are now user-managed. Use mix deploy_ex.upgrade_priv after upgrading deploy_ex.")
        end

      {:error, e} ->
        Mix.raise("#{__MODULE__}: failed to render templates, error: #{inspect(e)}")
    end
  end

  defp copy_rendered_to_deploy(temp_dir, deploy_folder, opts) do
    temp_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.each(fn src_path ->
      relative = Path.relative_to(src_path, temp_dir)
      dest = Path.join(deploy_folder, relative)

      File.mkdir_p!(Path.dirname(dest))

      if File.exists?(dest) and not opts[:force] do
        unless opts[:quiet] do
          Mix.shell().info([:yellow, "* skipping ", :reset, dest, " (exists)"])
        end
      else
        File.cp!(src_path, dest)

        unless opts[:quiet] do
          Mix.shell().info([:green, "* exported ", :reset, dest])
        end
      end
    end)
  end

  defp write_manifest(temp_dir, deploy_folder) do
    manifest =
      temp_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.reduce(
        [deploy_ex_version: to_string(Application.spec(:deploy_ex, :vsn)), files: []],
        fn file_path, acc ->
          relative = Path.relative_to(file_path, temp_dir)
          hash = file_path |> File.read!() |> DeployEx.PrivManifest.hash_content()
          DeployEx.PrivManifest.put_file(acc, relative, hash)
        end
      )

    DeployEx.PrivManifest.write(deploy_folder, manifest)
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet],
      switches: [force: :boolean, quiet: :boolean]
    )

    opts
  end
end
