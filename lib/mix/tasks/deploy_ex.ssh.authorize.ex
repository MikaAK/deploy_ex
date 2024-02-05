defmodule Mix.Tasks.DeployEx.Ssh.Authorize do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Add or remove ssh authorization to the internal network for specific IPs"
  @moduledoc """

  ### Example
  ```bash
  $ mix deploy_ex.ssh.authorize
  $ mix deploy_ex.ssh.authorize --remove
  $ mix deploy_ex.ssh.authorize -r # Short for remove
  $ mix deploy_ex.ssh.authorize --ip 101.123.3.4 # Short for remove
  ```

  This allows you to run other commands from `deploy_ex.ssh` with authorization into the ssh network

  ### Options
  - `remove` (`-r`) - Remove authorization instead of adding it
  - `ip` - IP to whitelist (by default uses the current devices IP)
  """

  def run(args) do
    Application.ensure_all_started(:deploy_ex)

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
