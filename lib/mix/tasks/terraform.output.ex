defmodule Mix.Tasks.Terraform.Output do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Displays terraform output values"
  @moduledoc """
  Displays output values from the Terraform state, such as instance IPs, database endpoints, and other
  configured outputs.

  ## Example
  ```bash
  mix terraform.output
  mix terraform.output --short
  ```

  ## Options
  - `directory` - Terraform directory path (default: #{@terraform_default_path})
  - `short` - Output as JSON for scripting (alias: `s`)
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      cmd = "output #{DeployEx.Terraform.parse_args(args, :output)}"

      cmd = if opts[:short], do: "#{cmd} --json", else: cmd

      result = if opts[:short] do
        DeployEx.Terraform.run_command(cmd, opts[:directory])
      else
        DeployEx.Terraform.run_command_with_console_log(cmd, opts[:directory])
      end

      maybe_parse_opts(result, opts[:short])
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [d: :directory, s: :short],
      switches: [
        directory: :string,
        short: :boolean
      ]
    )

    opts
  end

  defp maybe_parse_opts({json_results,  0}, true) do
    results = json_results
      |> Jason.decode!
      |> get_in(["public_ip", "value"])
      |> inspect(pretty: true)

    Mix.shell().info([:green, results])
  end

  defp maybe_parse_opts({results,  1}, false) do
    Mix.shell().error(ErrorMessage.failed_dependency("couldn't run #{DeployEx.Config.iac_tool()} output:\n#{results}"))
  end

  defp maybe_parse_opts(_, _), do: nil
end
