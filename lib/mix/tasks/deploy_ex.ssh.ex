defmodule Mix.Tasks.DeployEx.Ssh do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Ssh into a specific apps remote node"
  @moduledoc """
  ### Example
  ```bash
  $ mix deploy_ex.ssh my_app
  $ mix deploy_ex.ssh my_app 2 # with a specific node
  ```
  """

  def run(args) do
    {opts, app_params} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, pem_file_path} <- find_pem_file(opts[:directory]),
         {:ok, hostname_ips} <- Mix.Tasks.Ansible.Build.terraform_instance_ips(opts[:directory]) do
      case app_params do
        [app_name] -> connect_to_host(hostname_ips, app_name, pem_file_path, opts)
        [_, _] -> Mix.shell().error("Specifying a node isn't setup yet")
      end
    end
  end

  defp parse_args(args) do
    {opts, extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, s: :short],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        short: :boolean
      ]
    )

    {opts, extra_args}
  end

  defp connect_to_host(hostname_ips, app_name, pem_file_path, opts) do
    case Enum.find(hostname_ips, fn {key, _} -> key =~ app_name end) do
      nil ->
        host_name_ips = inspect(hostname_ips, pretty: true)
        Mix.shell().error("Couldn't find any app with the name of #{app_name}\n#{host_name_ips}")

      {app_name, ip_addresses} ->
        ip = Enum.random(ip_addresses)


        if opts[:short] do
          Mix.shell().info("ssh -i #{pem_file_path} admin@#{ip}")
        else
          Mix.shell().info([
            :green, "Use the follwing comand to connect to ",
            :reset, app_name, :green, " \"",
            :reset, "ssh -i #{pem_file_path} admin@#{ip}",
            :green, "\""
          ])
        end

        # When using Rambo re-enable
        # Mix.shell().info([
        #   :green, "Attempting to connect to ",
        #   :reset, app_name, :green, " at ",
        #   :reset, ip, :green, " using pem file ",
        #   :reset, pem_file_path
        # ])

        # with {:error, e} <- DeployExHelpers.run_command_with_input("ssh -i #{pem_file_path} admin@#{ip}", "") do
        #   Mix.shell().error(to_string(e))
        # end
    end
  end

  defp find_pem_file(terraform_directory) do
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
end