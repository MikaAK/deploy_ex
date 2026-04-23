defmodule Mix.Tasks.DeployEx.Qa do
  use Mix.Task

  @shortdoc "Overview of QA node commands and usage"
  @moduledoc """
  Displays an overview of all QA node commands with detailed usage information.

  QA nodes are standalone EC2 instances that run specific release versions for
  testing purposes. They can be attached to load balancers for integration testing.

  ## Example
  ```bash
  mix deploy_ex.qa
  mix deploy_ex.qa --command create
  mix deploy_ex.qa --command deploy
  ```

  ## Options
  - `--command, -c` - Show detailed help for a specific command
  """

  @commands [
    {"create", "Creates a new QA node with a specific SHA"},
    {"list", "Lists all active QA nodes"},
    {"deploy", "Deploys a specific SHA to an existing QA node"},
    {"destroy", "Destroys a QA node"},
    {"ssh", "Get SSH connection info for a QA node"},
    {"attach_lb", "Attaches a QA node to the app's load balancer"},
    {"detach_lb", "Detaches a QA node from the load balancer"},
    {"cleanup", "Cleans up orphaned QA nodes"}
  ]

  def run(args) do
    {opts, _extra_args} = parse_args(args)

    if is_nil(opts[:command]) do
      print_overview()
    else
      print_command_help(opts[:command])
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [c: :command],
      switches: [command: :string]
    )
  end

  defp print_overview do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}DeployEx QA Node Management#{IO.ANSI.reset()}
    #{String.duplicate("=", 50)}

    QA nodes are standalone EC2 instances that run specific release versions
    for testing purposes. They can be attached to load balancers for integration
    testing and easily destroyed when no longer needed.

    #{IO.ANSI.yellow()}Available Commands:#{IO.ANSI.reset()}
    """)

    Enum.each(@commands, fn {name, description} ->
      Mix.shell().info("  #{IO.ANSI.green()}mix deploy_ex.qa.#{name}#{IO.ANSI.reset()}")
      Mix.shell().info("      #{description}\n")
    end)

    Mix.shell().info("""
    #{IO.ANSI.yellow()}Quick Start Workflow:#{IO.ANSI.reset()}

    1. #{IO.ANSI.cyan()}Create a QA node#{IO.ANSI.reset()}
       mix deploy_ex.qa.create my_app --sha abc1234

    2. #{IO.ANSI.cyan()}Check the node status#{IO.ANSI.reset()}
       mix deploy_ex.qa.list

    3. #{IO.ANSI.cyan()}SSH into the node#{IO.ANSI.reset()}
       mix deploy_ex.qa.ssh my_app

    4. #{IO.ANSI.cyan()}Attach to load balancer (optional)#{IO.ANSI.reset()}
       mix deploy_ex.qa.attach_lb my_app

    5. #{IO.ANSI.cyan()}Deploy a different SHA#{IO.ANSI.reset()}
       mix deploy_ex.qa.deploy my_app --sha def5678

    6. #{IO.ANSI.cyan()}Destroy when done#{IO.ANSI.reset()}
       mix deploy_ex.qa.destroy my_app

    #{IO.ANSI.yellow()}For detailed help on a specific command:#{IO.ANSI.reset()}
      mix deploy_ex.qa --command <command_name>
      mix help deploy_ex.qa.<command_name>
    """)
  end

  defp print_command_help("create") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.create#{IO.ANSI.reset()} - Creates a new QA node

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.create <app_name> [--sha <sha>]

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.create my_app                          # prompt for QA SHA on current branch
      mix deploy_ex.qa.create my_app --sha abc1234
      mix deploy_ex.qa.create my_app --sha abc1234 --tag my-feature
      mix deploy_ex.qa.create my_app --sha abc1234 --public-ip-cert
      mix deploy_ex.qa.create my_app --sha abc1234 --attach-lb
      mix deploy_ex.qa.create my_app --sha abc1234 --skip-setup --skip-deploy
      mix deploy_ex.qa.create my_app --sha abc1234 --use-ami
      mix deploy_ex.qa.create my_app --sha abc1234 --instance-type t3.medium

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --sha, -s              Target git SHA; if omitted, picks from QA releases on current branch
      --tag, -t              Custom label used in the instance name (replaces the short SHA)
      --instance-type        EC2 instance type (default: t3.small)
      --skip-setup           Skip Ansible setup after creation
      --skip-deploy          Skip deployment after setup
      --attach-lb            Attach to load balancer after deployment
      --use-ami              Boot from the app's pre-baked AMI (skips setup). Default off for QA
      --public-ip-cert       Issue Let's Encrypt cert for the node's public IP (short-lived)
      --force, -f            Replace existing QA node without prompting
      --quiet, -q            Suppress output messages
      --aws-region           AWS region (default: from config)
      --aws-release-bucket   S3 bucket for releases (default: from config)

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Creates a new EC2 instance configured as a QA node for the specified app.
      The instance is tagged with QaNode=true, TargetSha, GitBranch, InstanceTag,
      and UsePublicIpCert — the aws_ec2 inventory maps these to host vars so every
      subsequent ansible run picks up the right per-node context automatically.

      By default QA nodes boot from the base AMI and run fresh setup + deploy.
      Use --use-ami to boot from the app's pre-baked AMI (skips setup).

      Use --public-ip-cert for standalone QA nodes that need a valid cert on their
      public IP (not behind a load balancer). The flag is persisted in S3 state so
      ansible picks it up on every subsequent run.
    """)
  end

  defp print_command_help("list") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.list#{IO.ANSI.reset()} - Lists all active QA nodes

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.list

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.list
      mix deploy_ex.qa.list --app my_app
      mix deploy_ex.qa.list --json

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --app, -a    Filter by app name
      --json       Output as JSON
      --quiet, -q  Minimal output

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Lists all QA nodes with their current status: instance name, ID,
      target SHA, custom tag, git branch, public IP, IPv6, load balancer
      attachment, and creation time. JSON output exposes the same fields
      (instance_tag, git_branch) for scripting.
    """)
  end

  defp print_command_help("deploy") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.deploy#{IO.ANSI.reset()} - Deploys a specific SHA to an existing QA node

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.deploy <app_name> --sha <sha>

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.deploy my_app --sha def5678
      mix deploy_ex.qa.deploy my_app --sha def5678 --instance-id i-0abc123
      mix deploy_ex.qa.deploy my_app --sha def5678 --public-ip-cert
      mix deploy_ex.qa.deploy my_app --sha def5678 --no-public-ip-cert

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --sha, -s                              Target git SHA (required)
      --instance-id, -i                      Target a specific QA instance when multiple exist
      --public-ip-cert / --no-public-ip-cert Toggle public-IP LE cert mode (persisted to tag+state)
      --quiet, -q                            Suppress output messages
      --aws-region                           AWS region (default: from config)
      --aws-release-bucket                   S3 bucket for releases (default: from config)

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Deploys a different release version to an existing QA node. The SHA is
      resolved against both the qa/ and prod/ release prefixes in S3.

      When multiple QA nodes exist for the app, an interactive picker lets you
      choose which to redeploy (or pass --instance-id to pick directly). The
      redeploy also updates the node's S3 state with the new SHA and current
      git branch.
    """)
  end

  defp print_command_help("destroy") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.destroy#{IO.ANSI.reset()} - Destroys one or more QA nodes

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.destroy <app_name>

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.destroy my_app                   # pick from my_app's QA nodes
      mix deploy_ex.qa.destroy my_app --instance-id i-0abc123
      mix deploy_ex.qa.destroy --all                    # every QA node across all apps
      mix deploy_ex.qa.destroy my_app --force

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --instance-id, -i  Destroy a specific instance by ID (skips picker)
      --all              Destroy every QA node across all apps
      --force, -f        Skip confirmation prompt
      --quiet, -q        Suppress output messages

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Terminates the EC2 instance(s) and cleans up the S3 state file.

      With an app name and no --instance-id, a single node is destroyed
      directly; multiple nodes open an interactive picker so you can choose
      which to destroy (or select all).

      Load-balancer-attached nodes are detached before termination.
    """)
  end

  defp print_command_help("ssh") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.ssh#{IO.ANSI.reset()} - Get SSH connection info for a QA node

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.ssh <app_name>

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.ssh my_app
      mix deploy_ex.qa.ssh my_app --short
      mix deploy_ex.qa.ssh my_app --root
      mix deploy_ex.qa.ssh my_app --log
      mix deploy_ex.qa.ssh my_app --iex

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --short, -s  Output command only (for eval)
      --root       Connect as root
      --log        View application logs
      --iex        Connect to remote IEx
      --quiet, -q  Suppress output

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Displays SSH connection information for the QA node.

      Use --short to get just the command for use with eval:
        eval "$(mix deploy_ex.qa.ssh my_app -s)"

      Use --log to tail the application logs:
        mix deploy_ex.qa.ssh my_app --log

      Use --iex to connect to the running application's IEx console:
        mix deploy_ex.qa.ssh my_app --iex
    """)
  end

  defp print_command_help("attach_lb") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.attach_lb#{IO.ANSI.reset()} - Attaches a QA node to the app's load balancer

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.attach_lb <app_name>

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.attach_lb my_app
      mix deploy_ex.qa.attach_lb my_app --port 4000
      mix deploy_ex.qa.attach_lb my_app --target-group arn:aws:...
      mix deploy_ex.qa.attach_lb my_app --wait

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --target-group  Specific target group ARN (default: auto-discover)
      --port          Port to register (default: 4000)
      --wait          Wait for health check to pass
      --quiet, -q     Suppress output messages

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Registers the QA node with the app's load balancer target groups.

      By default, target groups are auto-discovered based on the app name.
      Use --target-group to specify a specific target group ARN.

      Use --wait to block until the health check passes.
    """)
  end

  defp print_command_help("detach_lb") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.detach_lb#{IO.ANSI.reset()} - Detaches a QA node from the load balancer

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.detach_lb <app_name>

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.detach_lb my_app
      mix deploy_ex.qa.detach_lb my_app --target-group arn:aws:...

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --target-group  Specific target group ARN (default: all attached)
      --quiet, -q     Suppress output messages

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Deregisters the QA node from all attached load balancer target groups.

      Use --target-group to detach from a specific target group only.
    """)
  end

  defp print_command_help("health") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.health#{IO.ANSI.reset()} - Check load balancer health status for QA nodes

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.health

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.health
      mix deploy_ex.qa.health my_app
      mix deploy_ex.qa.health --all
      mix deploy_ex.qa.health --watch
      mix deploy_ex.qa.health --json

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --all         Check health for all apps (not just QA nodes)
      --watch, -w   Continuously monitor (refresh every 5s)
      --json        Output as JSON
      --quiet, -q   Minimal output

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Displays the load balancer health status for QA nodes and their
      associated target groups.

      Use --watch to continuously monitor health status with auto-refresh.

      Use --all to see health status for all instances, not just QA nodes.
    """)
  end

  defp print_command_help("cleanup") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.qa.cleanup#{IO.ANSI.reset()} - Cleans up orphaned QA nodes

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.qa.cleanup

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.qa.cleanup
      mix deploy_ex.qa.cleanup --dry-run
      mix deploy_ex.qa.cleanup --force

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --dry-run    Show what would be cleaned up without taking action
      --force, -f  Skip confirmation prompt
      --quiet, -q  Suppress output messages

    #{IO.ANSI.yellow()}Description:#{IO.ANSI.reset()}
      Detects and cleans up orphaned QA nodes where:
      - S3 state exists but the instance is terminated or not found
      - EC2 instances exist with QA tags but no corresponding S3 state

      Use --dry-run to preview what would be cleaned up without making changes.
    """)
  end

  defp print_command_help(unknown) do
    Mix.shell().error("Unknown command: #{unknown}")
    Mix.shell().info("\nAvailable commands:")

    Enum.each(@commands, fn {name, _} ->
      Mix.shell().info("  #{name}")
    end)
  end
end
