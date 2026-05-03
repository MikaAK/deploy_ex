defmodule Mix.Tasks.DeployEx.InstallMigrationScript do
  use Mix.Task

  @scripts_default_path Path.join(["rel", "overlays", "bin"])

  @shortdoc "Installs a migration script for running Ecto migrations in releases"
  @moduledoc """
  Generates a single shell script for running Ecto database migrations in
  release deployments.

  One script is written per repo (not per app or release). Mix copies the
  `rel/overlays/bin/` directory into every release tarball, so the same
  `migrate.sh` ends up at `/srv/<release>/bin/migrate.sh` on each server.

  At runtime the script:
  1. Derives its own release name from its filesystem location (so the same
     file works inside any release).
  2. Loads every umbrella app, skipping apps not packaged in the current
     release.
  3. Collects `:ecto_repos` from each loaded app and runs migrations.

  The script supports two commands:
  - `migrate` - run all pending migrations (default)
  - `rollback VERSION` - roll back to the given migration version

  ## Example
  ```bash
  mix deploy_ex.install_migration_script
  mix release

  # Then on the server (works identically for every release):
  /srv/my_app/bin/migrate.sh migrate
  /srv/my_app/bin/migrate.sh rollback 20240101120000
  ```

  ## Options
  - `force` - Overwrite the existing script if present (alias: `f`)
  - `quiet` - Suppress output messages (alias: `q`)
  - `directory` - Output directory (default: `rel/overlays/bin`) (alias: `d`)
  """

  def run(args) do
    opts = args
      |> parse_args()
      |> Keyword.put_new(:directory, @scripts_default_path)

    migration_script_template_path = DeployExHelpers.priv_folder("migration_script.sh.eex")
    output_path = Path.join(opts[:directory], "migrate.sh")

    with :ok <- DeployExHelpers.check_valid_project() do
      File.mkdir_p!(opts[:directory])

      DeployExHelpers.write_template(
        migration_script_template_path,
        output_path,
        %{apps: DeployExHelpers.project_apps()},
        opts
      )

      File.chmod!(output_path, 0o755)
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
