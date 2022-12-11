defmodule Mix.Tasks.Terraform.Replace do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Runs terraform replace with a node"
  @moduledoc """
  Runs terraform init

  ## Example
  ```bash
  $ mix terraform.replace <my_app>
  $ mix terraform.replace <my_app> --node 10
  $ mix terraform.replace <my_app> -n 10
  $ mix terraform.replace --string "module.vpc.aws_route_table.public[0]"
  ```
  """

  def run(args) do
    {opts, extra_args} = parse_args(args)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      if opts[:string] do
        terraform_apply_replace(opts[:string], opts)
      else
        match_instance_from_terraform_and_replace(opts, extra_args)
      end
    end
  end

  defp match_instance_from_terraform_and_replace(opts, extra_args) do
    case DeployExHelpers.terraform_instances(opts[:directory]) do
      {:error, e} -> Mix.raise(to_string(e))

      {:ok, instances} ->
        instances
          |> get_instances_from_args(extra_args, opts)
          |> Enum.map(fn {instance_name, node_num} ->
            Mix.shell().info([:yellow, "* replacing #{instance_name}-#{node_num}"])

            instance_name
              |> replace_string(node_num)
              |> terraform_apply_replace(opts)
          end)
    end
  end

  defp terraform_apply_replace(replace_str, opts) do
    cmd = "terraform apply --replace \"#{replace_str}\""
    cmd = if opts[:auto_approve], do: "#{cmd} --auto-approve", else: cmd

    DeployExHelpers.run_command_with_input(cmd, opts[:directory])
  end

  defp replace_string(instance_name, node_num) do
    "module.ec2_instance[\\\"#{instance_name}\\\"].aws_instance.ec2_instance[#{node_num || 0}]"
  end

  defp parse_args(args) do
    {opts, extra_args} = OptionParser.parse!(args,
      aliases: [d: :directory, y: :auto_approve, n: :node, s: :string],
      switches: [
        string: :string,
        directory: :string,
        node: :integer,
        all: :boolean,
        auto_approve: :boolean
      ]
    )

    {Keyword.put_new(opts, :directory, @terraform_default_path), extra_args}
  end

  defp get_instances_from_args(instances, [instance_name], opts) do
    node_num = opts[:node]

    selected_instances = Enum.filter(instances, fn
      {name, ^node_num} -> name =~ instance_name
      {name, _} -> name =~ instance_name
    end)

    if length(selected_instances) > 1 and !opts[:all] do
      Mix.raise("""
      #{IO.ANSI.reset() <> IO.ANSI.red()}Error with arguments provided, `#{IO.ANSI.format([:bright, :italic, instance_name, :reset])}#{IO.ANSI.red()}` is ambiguous

      It could refer to either of the following:
      #{instances_to_list_str(selected_instances)}

      To prevent this please specify either one of the following:
        - #{IO.ANSI.format([:bright, "`--node`"])}#{IO.ANSI.red()} to target the specific node number
        - #{IO.ANSI.format([:bright, "`--all`"])}#{IO.ANSI.red()} to target all the nodes
      """)
    end

    if length(selected_instances) === 0 do
      Mix.raise("""
      #{IO.ANSI.reset() <> IO.ANSI.red()}No instances were found using #{IO.ANSI.format([:bright, :italic, instance_name, :reset])}#{IO.ANSI.red()}, the following instances exist:

      #{instances_to_list_str(instances)}
      """)
    end

    selected_instances
  end

  defp get_instances_from_args(_, _, opts) do
    case DeployExHelpers.terraform_instances(opts[:directory]) do
      {:ok, instances} ->
        Mix.raise("""
        Error with arguments provided, must specify one app name or a resource string

          Examples:
            $ mix terraform.replace my_app
            $ mix terraform.replace my_app -n 1
            $ mix terraform.replace --string "module.ec2_instance[\"my_instance\"].aws_instance.ec2_instance[0]"

        #{instances_to_list_str(instances)}
        """)
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp instances_to_list_str(instances) do
    Enum.map_join(instances, "\n", fn {name, num} ->
      "  - #{IO.ANSI.bright() <> name} - #{to_string(num) <> IO.ANSI.reset() <> IO.ANSI.red()}"
    end)
  end
end

