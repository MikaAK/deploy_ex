defmodule Mix.Tasks.Terraform.Plan do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Shows terraform's potential changes if you were to apply"
  @moduledoc """
  Runs `terraform plan` to preview infrastructure changes without applying them.

  ## Example
  ```bash
  mix terraform.plan
  mix terraform.plan --target my_app
  ```

  ## Options
  - `directory` - Terraform directory path (default: #{@terraform_default_path})
  - `quiet` - Suppress output messages
  - `var-file` - Path to a Terraform variables file
  - `target` - Target specific app resources (can be used multiple times)
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- terraform_plan(args, opts) do
      :ok
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
      ]
    )

    opts
  end

  defp terraform_plan(args, opts) do
    DeployEx.Terraform.run_command_with_input(
      "plan #{DeployEx.Terraform.parse_args(args, :plan)}",
      opts[:directory]
    )
  end
end
