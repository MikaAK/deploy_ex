defmodule Mix.Tasks.DeployEx.Ssh.Authorize do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Add or remove ssh authorization to the internal network for specific IPs"
  @moduledoc """
  Manages SSH authorization by adding or removing IP addresses from the AWS security group whitelist.

  This task allows you to:
  1. Add your current IP address to the security group whitelist
  2. Add a specific IP address to the whitelist
  3. Remove IP addresses from the whitelist

  Once authorized, you can use other `deploy_ex.ssh` commands to interact with instances in the network.

  ## Example
  ```bash
  # Authorize current IP address
  mix deploy_ex.ssh.authorize

  # Authorize specific IP address
  mix deploy_ex.ssh.authorize --ip 101.123.3.4

  # Remove current IP from whitelist
  mix deploy_ex.ssh.authorize --remove
  mix deploy_ex.ssh.authorize -r  # Short form

  # Remove specific IP from whitelist
  mix deploy_ex.ssh.authorize --remove --ip 101.123.3.4
  ```

  ## Options
  - `directory` (`-d`) - Directory containing Terraform files (default: ./deploys/terraform)
  - `force` (`-f`) - Skip confirmation prompts
  - `quiet` (`-q`) - Suppress output messages
  - `remove` (`-r`) - Remove authorization instead of adding it
  - `ip` - Specific IP address to whitelist (defaults to current device's IP)
  """

  def run(args) do
    Enum.each([:req, :hackney, :ex_aws], &Application.ensure_all_started/1)

    opts = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, security_group_id} <- DeployExHelpers.terraform_security_group_id(opts[:directory]),
         :ok <- add_or_remove_whitelist(opts, security_group_id) do
      :ok
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet, d: :directory, r: :remove],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        remove: :boolean,
        ip: :string
      ]
    )

    opts
  end

  defp add_or_remove_whitelist(opts, security_group_id) do
    if opts[:remove] do
      revoke_whitelist(opts, security_group_id)
    else
      whitelist(opts, security_group_id)
    end
  end

  defp revoke_whitelist(opts, security_group_id) do
    with {:ok, current_ip} <- get_arg_id_or_current_ip(opts) do
      Mix.shell().info(IO.ANSI.format([:yellow, "Deauthorizing current device #{current_ip} from security group #{security_group_id}", :reset]))

      DeployEx.AwsIpWhitelister.deauthorize(security_group_id, current_ip)
    end
  end

  defp whitelist(opts, security_group_id) do
    with {:ok, current_ip} <- get_arg_id_or_current_ip(opts) do
      Mix.shell().info(IO.ANSI.format([:yellow, "Authorizing current device #{current_ip} in security group #{security_group_id}", :reset]))

      DeployEx.AwsIpWhitelister.authorize(security_group_id, current_ip)
    end
  end

  defp get_arg_id_or_current_ip(opts) do
    if opts[:ip] do
      {:ok, opts[:ip]}
    else
      DeployEx.IpFinder.current_ip()
    end
  end
end
