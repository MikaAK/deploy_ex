defmodule Mix.Tasks.DeployEx.LoadTest do
  use Mix.Task

  @shortdoc "Overview of k6 load testing commands and usage"
  @moduledoc """
  Displays an overview of all k6 load testing commands with detailed usage information.

  ## Example
  ```bash
  mix deploy_ex.load_test
  mix deploy_ex.load_test --command create_instance
  ```

  ## Options
  - `--command, -c` - Show detailed help for a specific command
  """

  @commands [
    {"init", "Scaffolds k6 test scripts for an app"},
    {"create_instance", "Creates a k6 runner EC2 instance"},
    {"destroy_instance", "Destroys a k6 runner instance"},
    {"list", "Lists all active k6 runner instances"},
    {"upload", "Uploads k6 scripts to a runner"},
    {"exec", "Executes a k6 test on a runner"}
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

    #{IO.ANSI.cyan()}DeployEx k6 Load Testing#{IO.ANSI.reset()}
    #{String.duplicate("=", 50)}

    Run k6 load tests against your deployed applications using ephemeral
    EC2 runner instances. Results are pushed to Prometheus via remote write
    and can be visualized in Grafana.

    #{IO.ANSI.yellow()}Available Commands:#{IO.ANSI.reset()}
    """)

    Enum.each(@commands, fn {name, description} ->
      Mix.shell().info("  #{IO.ANSI.green()}mix deploy_ex.load_test.#{name}#{IO.ANSI.reset()}")
      Mix.shell().info("      #{description}\n")
    end)

    Mix.shell().info("""
    #{IO.ANSI.yellow()}Quick Start Workflow:#{IO.ANSI.reset()}

    1. #{IO.ANSI.cyan()}Scaffold test scripts#{IO.ANSI.reset()}
       mix deploy_ex.load_test.init my_app

    2. #{IO.ANSI.cyan()}Create a k6 runner#{IO.ANSI.reset()}
       mix deploy_ex.load_test.create_instance

    3. #{IO.ANSI.cyan()}Upload scripts#{IO.ANSI.reset()}
       mix deploy_ex.load_test.upload my_app

    4. #{IO.ANSI.cyan()}Run the test#{IO.ANSI.reset()}
       mix deploy_ex.load_test.exec my_app

    5. #{IO.ANSI.cyan()}Install the k6 Grafana dashboard#{IO.ANSI.reset()}
       mix deploy_ex.grafana.install_dashboard --id 19665

    6. #{IO.ANSI.cyan()}Destroy the runner when done#{IO.ANSI.reset()}
       mix deploy_ex.load_test.destroy_instance

    #{IO.ANSI.yellow()}For detailed help on a specific command:#{IO.ANSI.reset()}
      mix deploy_ex.load_test --command <command_name>
      mix help deploy_ex.load_test.<command_name>
    """)
  end

  defp print_command_help("init") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.load_test.init#{IO.ANSI.reset()} - Scaffolds k6 test scripts

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.load_test.init <app_name>

    #{IO.ANSI.yellow()}Examples:#{IO.ANSI.reset()}
      mix deploy_ex.load_test.init my_app

    Creates deploys/k6/scripts/<app_name>/load_test.js with a parametrized
    k6 test script template.
    """)
  end

  defp print_command_help("create_instance") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.load_test.create_instance#{IO.ANSI.reset()} - Creates a k6 runner

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.load_test.create_instance [options]

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --instance-type    EC2 instance type (default: t3.small)
      --force, -f        Replace existing runner without prompting
      --quiet, -q        Suppress output messages

    Provisions an EC2 instance with k6 pre-installed. Checks for an existing
    runner first and reuses it unless --force is provided.
    """)
  end

  defp print_command_help("destroy_instance") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.load_test.destroy_instance#{IO.ANSI.reset()} - Destroys a k6 runner

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.load_test.destroy_instance [options]

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --instance-id, -i  Specific instance ID to destroy
      --all              Destroy all k6 runners
      --force, -f        Skip confirmation prompt
      --quiet, -q        Suppress output messages
    """)
  end

  defp print_command_help("list") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.load_test.list#{IO.ANSI.reset()} - Lists active k6 runners

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.load_test.list [options]

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --json       Output as JSON
      --quiet, -q  Minimal output
    """)
  end

  defp print_command_help("upload") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.load_test.upload#{IO.ANSI.reset()} - Uploads k6 scripts to a runner

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.load_test.upload <app_name> [options]

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --script          Path to specific script (default: all in deploys/k6/scripts/<app>/)
      --instance-id, -i Specific runner instance ID
      --quiet, -q       Suppress output messages

    Uploads scripts via SCP to /srv/k6/scripts/ on the runner.
    """)
  end

  defp print_command_help("exec") do
    Mix.shell().info("""

    #{IO.ANSI.cyan()}mix deploy_ex.load_test.exec#{IO.ANSI.reset()} - Executes a k6 test on a runner

    #{IO.ANSI.yellow()}Usage:#{IO.ANSI.reset()}
      mix deploy_ex.load_test.exec <app_name> [options]

    #{IO.ANSI.yellow()}Options:#{IO.ANSI.reset()}
      --script           Script filename (default: load_test.js)
      --target-url       Application endpoint URL
      --prometheus-url   Prometheus remote write URL (default: http://10.0.1.40:9090)
      --instance-id, -i  Specific runner instance ID
      --quiet, -q        Suppress output messages

    Runs the k6 test via SSH, streaming output. Results are pushed to Prometheus
    via remote write for visualization in Grafana.
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
