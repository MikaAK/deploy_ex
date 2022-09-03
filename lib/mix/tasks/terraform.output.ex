defmodule Mix.Tasks.Terraform.Output do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Gets terraform output"
  @moduledoc """
  Gets the results from terraform.output command
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      cmd = "terraform output"

      cmd = if opts[:short], do: "#{cmd} --json", else: cmd

      shell_opts = [cd: opts[:directory]]

      shell_opts = if opts[:short], do: shell_opts, else: [{:into, IO.stream()} | shell_opts]

      cmd
        |> System.shell(shell_opts)
        |> maybe_parse_ipts(opts[:short])
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

  defp maybe_parse_ipts({json_results,  0}, true) do
    results = json_results
      |> Jason.decode!
      |> get_in(["public_ip", "value"])
      |> inspect(pretty: true)

    Mix.shell().info([:green, results])
  end

  defp maybe_parse_ipts({results,  1}, false) do
    Mix.shell().error(ErrorMessage.failed_dependency("couldn't run terraform output:\n#{results}"))
  end

  defp maybe_parse_ipts(_, _), do: nil
end
