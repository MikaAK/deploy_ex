defmodule Mix.Tasks.Terraform.Refresh do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Refreshes terraform state to sync with actual AWS resources"
  @moduledoc """
  Refreshes the Terraform state to sync with actual AWS resources. Useful when
  instance IPs or other attributes have changed outside of Terraform.

  ## Example
  ```bash
  mix terraform.refresh
  ```

  ## Options
  - `directory` - Terraform directory path (default: #{@terraform_default_path})
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      DeployEx.Terraform.run_command_with_input(
        "refresh #{DeployEx.Terraform.parse_args(args, :refresh)}",
        opts[:directory]
      )
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean
      ]
    )

    opts
  end
end
