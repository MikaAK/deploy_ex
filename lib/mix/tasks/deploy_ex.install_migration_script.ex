defmodule Mix.Tasks.DeployEx.InstallMigrationScript do
  use Mix.Task

  @scripts_default_path Path.join(DeployEx.Config.deploy_folder(), "scripts")
  @migration_script_template_path DeployExHelpers.priv_file("migration_script.sh.eex")

  @shortdoc "Installs migration scripts for running Ecto migrations in releases"
  @moduledoc """
  Generates shell scripts for running Ecto database migrations in release deployments.

  For each configured release, a migration script is generated that uses
  `Ecto.Migrator.with_repo/3` to safely run migrations via `bin/<app> eval`.
  The scripts discover `:ecto_repos` from each application at runtime.

  Each generated script supports two commands:
  - `migrate` - Runs all pending migrations (default)
  - `rollback VERSION` - Rolls back to the given migration version

  ## Example
  ```bash
  mix deploy_ex.install_migration_script

  # Then on the server:
  ./deploys/scripts/migrate-my_app.sh migrate
  ./deploys/scripts/migrate-my_app.sh rollback 20240101120000
  ```

  ## Options
  - `force` - Overwrite existing migration scripts if present (alias: `f`)
  - `quiet` - Suppress output messages (alias: `q`)
  - `directory` - Output directory for scripts (default: `./deploys/scripts`) (alias: `d`)
  """

  def run(args) do
    opts = args
      |> parse_args()
      |> Keyword.put_new(:directory, @scripts_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.release_apps_by_release_name() do
      File.mkdir_p!(opts[:directory])

      Enum.each(releases, fn {release_name, apps} ->
        app_name = to_string(release_name)
        output_path = Path.join(opts[:directory], "migrate-#{app_name}.sh")

        DeployExHelpers.write_template(
          @migration_script_template_path,
          output_path,
          %{
            app_name: app_name,
            apps: Enum.map(apps, &String.to_atom/1)
          },
          opts
        )

        File.chmod!(output_path, 0o755)
      end)
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet, d: :directory],
      switches: [
        force: :boolean,
        quiet: :boolean,
        directory: :string
      ]
    )

    opts
  end
end
