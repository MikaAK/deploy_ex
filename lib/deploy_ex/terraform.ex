defmodule DeployEx.Terraform do
  @terraform_flags [
    var_file: :string
  ]

  def parse_args(args) do
    {terraform_opts, _extra_args, _invalid_args} = OptionParser.parse(args,
      strict: @terraform_flags
    )

    terraform_opts |> OptionParser.to_argv(@terraform_flags) |> Enum.join(" ")
  end

  def run_command(command, terraform_directory) do
    DeployEx.Utils.run_command_with_return(
      "#{DeployEx.Config.iac_tool()} #{command}",
      terraform_directory
    )
  end

  def run_command_with_input(command, terraform_directory) do
    DeployEx.Utils.run_command_with_input(
      "#{DeployEx.Config.iac_tool()} #{command}",
      terraform_directory
    )
  end

  def run_command_with_console_log(command, terraform_directory) do
    DeployEx.Utils.run_command(
      "#{DeployEx.Config.iac_tool()} #{command}",
      terraform_directory
    )
  end

  def find_pem_file(terraform_directory, pem_file) when is_nil(pem_file) do
    res = terraform_directory
      |> Path.join("*.pem")
      |> Path.wildcard()
      |> List.first

    if is_nil(res) do
      {:error, ErrorMessage.not_found("couldn't find pem file in #{terraform_directory}")}
    else
      {:ok, res}
    end
  end

  def find_pem_file(_terraform_directory, pem_file) do
    {:ok, pem_file}
  end

  def list_state(terraform_directory) do
    run_command("state list", terraform_directory)
  end

  def instances(terraform_directory) do
    with {:ok, output} <- list_state(terraform_directory) do
      output
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/module.ec2_instance.*ec2_instance/))
        |> Enum.map(fn resource ->
          case Regex.run(
            ~r/module\.ec2_instance\["(.*?)"\]\.aws_instance\.ec2_instance\[(.*)\]/,
            resource
          ) do
            [_, node, num] -> {node, String.to_integer(num)}
            _ -> Mix.raise("Error decoding node numbers from resource: #{resource}")
          end
        end)
        |> then(&{:ok, &1})
    end
  end

  def security_group_id(terraform_directory) do
    terraform_state_show = """
    state show 'module.app_security_group.module.sg.aws_security_group.this_name_prefix[0]' \
    | grep 'id.*sg-' \
    | awk '{print $3}' \
    | awk '{print substr($0, 2, length($0) - 2)}'
    """

    with {:ok, output} <- run_command(terraform_state_show, terraform_directory) do
      security_group_id = String.trim(output)

      if security_group_id === "" do
        {:error, ErrorMessage.not_found("couldn't pull out security group id from terraform")}
      else
        {:ok, security_group_id}
      end
    end
  end

  def terraform_instance_ips(terraform_directory) do
    with {:ok, output} <- run_command("output --json", terraform_directory) do
      {:ok, parse_terraform_output_to_ips(output)}
    end
  end

  defp parse_terraform_output_to_ips(output) do
    case Jason.decode!(output) do
      %{"public_ips" => %{"value" => values}} -> values
      _ -> []
    end
  end

  def terraform_ipv6_addresses(terraform_directory) do
    with {:ok, output} <- run_command("output --json", terraform_directory) do
      {:ok, parse_terraform_output_to_ipv6_addresses(output)}
    end
  end

  defp parse_terraform_output_to_ipv6_addresses(output) do
    case Jason.decode!(output) do
      %{"ipv6_addresses" => %{"value" => values}} -> values
      _ -> []
    end
  end
end
