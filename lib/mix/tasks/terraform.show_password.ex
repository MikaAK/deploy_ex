defmodule Mix.Tasks.Terraform.ShowPassword do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Shows passwords for databases in the cluster"
  @moduledoc """
  Shows the password for databases within Terraform.

  ## Example:
  ```bash
  mix terraform.show_password database_name
  mix terraform.show_password database_name --backend local
  mix terraform.show_password database_name --backend s3
  ```

  ## Options
  - `--directory` - Terraform directory path (used for local backend)
  - `--backend` - State backend: "s3" or "local" (default: from config)
  - `--bucket` - S3 bucket for state (default: from config)
  - `--region` - AWS region (default: from config)
  """

  def run(args) do
    {opts, extra_args} = parse_args(args)
    directory = opts[:directory] || @terraform_default_path
    state_opts = build_state_opts(opts)

    maybe_start_aws_apps(state_opts[:backend])

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, state} <- DeployEx.TerraformState.read_state(directory, state_opts),
         database_name when not is_nil(database_name) <- List.first(extra_args) || show_database_selection(state),
         {:ok, password} <- DeployEx.TerraformState.get_resource_attribute_by_tag(
           state,
           "aws_db_instance",
           "Name",
           database_name,
           "password"
         ) do
      Mix.shell().info([:green, "Password for #{database_name}: ", :reset, password])
    else
      nil -> Mix.raise("No database name provided")
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp show_database_selection(state) do
    case get_databases_from_state(state) do
      [] -> nil
      [single_db] -> single_db
      multiple_dbs ->
        [choice] = DeployExHelpers.prompt_for_choice(multiple_dbs)
        choice
    end
  end

  defp get_databases_from_state(state) do
    state["resources"]
    |> Enum.filter(&(&1["type"] == "aws_db_instance"))
    |> Enum.flat_map(fn resource ->
      case get_in(resource, ["instances", Access.at(0), "attributes", "tags"]) do
        tags when is_map(tags) -> [tags["Name"]]
        _ -> []
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [q: :quiet, d: :directory, b: :backend],
      switches: [
        directory: :string,
        quiet: :boolean,
        backend: :string,
        bucket: :string,
        region: :string
      ]
    )
  end

  defp build_state_opts(opts) do
    state_opts = []

    state_opts = if opts[:backend] do
      Keyword.put(state_opts, :backend, String.to_existing_atom(opts[:backend]))
    else
      state_opts
    end

    state_opts = if opts[:bucket], do: Keyword.put(state_opts, :bucket, opts[:bucket]), else: state_opts
    state_opts = if opts[:region], do: Keyword.put(state_opts, :region, opts[:region]), else: state_opts
    state_opts
  end

  defp maybe_start_aws_apps(:s3) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)
  end

  defp maybe_start_aws_apps(_), do: :ok
end
