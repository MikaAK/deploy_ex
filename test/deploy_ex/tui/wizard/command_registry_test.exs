defmodule DeployEx.TUI.Wizard.CommandRegistryTest do
  use ExUnit.Case, async: true

  alias DeployEx.TUI.Wizard.CommandRegistry

  @tasks_dir "lib/mix/tasks"

  @hidden_per_task %{
    # `--no-tui` is a tooling-internal flag set automatically when the wizard
    # invokes the task; users do not need to toggle it through the wizard UI.
    "ansible.deploy" => [:no_tui],
    "ansible.setup" => [:no_tui],
    "deploy_ex.autoscale.refresh" => [:no_tui],
    "deploy_ex.full_setup" => [:no_tui],
    "deploy_ex.load_balancer.health" => [:no_tui],
    "deploy_ex.qa.create" => [:no_tui],
    "deploy_ex.qa.deploy" => [:no_tui],
    "deploy_ex.remake" => [:no_tui],
    "deploy_ex.restart_app" => [:no_tui],
    "deploy_ex.restart_machine" => [:no_tui],
    "deploy_ex.start_app" => [:no_tui],
    "deploy_ex.stop_app" => [:no_tui]
  }

  # Tasks that accept positional arguments — these are surfaced as
  # `positional: true` inputs in the registry and never appear in the task's
  # OptionParser switch list. The wizard exposes them as text inputs instead.
  @positional_only_keys %{
    "deploy_ex.autoscale.scale" => [:desired_capacity],
    "deploy_ex.download_file" => [:remote_path, :local_path],
    "terraform.dump_database" => [:database_name],
    "terraform.restore_database" => [:database_name, :dump_file]
  }

  # Every task whose registry entry exposes an `app_name` positional input
  # but whose OptionParser does not declare an `app_name` switch.
  @app_name_positional MapSet.new([
    "deploy_ex.autoscale.refresh",
    "deploy_ex.autoscale.refresh_status",
    "deploy_ex.autoscale.scale",
    "deploy_ex.autoscale.status",
    "deploy_ex.download_file",
    "deploy_ex.find_nodes",
    "deploy_ex.instance.health",
    "deploy_ex.instance.status",
    "deploy_ex.list_app_release_history",
    "deploy_ex.load_balancer.health",
    "deploy_ex.load_test.exec",
    "deploy_ex.load_test.init",
    "deploy_ex.load_test.upload",
    "deploy_ex.qa.attach_lb",
    "deploy_ex.qa.create",
    "deploy_ex.qa.deploy",
    "deploy_ex.qa.destroy",
    "deploy_ex.qa.detach_lb",
    "deploy_ex.remake",
    "deploy_ex.restart_app",
    "deploy_ex.restart_machine",
    "deploy_ex.select_node",
    "deploy_ex.ssh",
    "deploy_ex.start_app",
    "deploy_ex.stop_app",
    "deploy_ex.view_current_release",
    "ansible.rollback",
    "terraform.create_ebs_snapshot",
    "terraform.delete_ebs_snapshot",
    "terraform.replace",
    "terraform.restore_database"
  ])

  describe "registry parity with Mix tasks" do
    test "every wizard option matches the task's OptionParser switch set" do
      results = Enum.map(CommandRegistry.all_commands(), &compare_entry/1)

      mismatches = Enum.reject(results, &match?(:ok, &1))

      assert mismatches === [], format_mismatches(mismatches)
    end
  end

  defp compare_entry(%{task: task, inputs: inputs}) do
    task_switches = task_switches_for(task)
    registry_keys = registry_flag_keys(task, inputs)

    hidden = MapSet.new(Map.get(@hidden_per_task, task, []))
    expected = MapSet.difference(task_switches, hidden)

    if MapSet.equal?(expected, registry_keys) do
      :ok
    else
      missing = MapSet.difference(expected, registry_keys)
      extra = MapSet.difference(registry_keys, expected)
      {task, MapSet.to_list(missing), MapSet.to_list(extra)}
    end
  end

  defp registry_flag_keys(task, inputs) do
    positional_extras = Map.get(@positional_only_keys, task, [])
    app_name_skip = if MapSet.member?(@app_name_positional, task), do: [:app_name], else: []
    skip = MapSet.new(positional_extras ++ app_name_skip)

    inputs
    |> Enum.reject(& &1.positional)
    |> Enum.map(& &1.key)
    |> Enum.reject(&MapSet.member?(skip, &1))
    |> MapSet.new()
  end

  defp task_switches_for("ansible.ping") do
    MapSet.new([:inventory, :limit, :extra_vars])
  end

  defp task_switches_for("deploy_ex.full_drop"), do: MapSet.new([])
  defp task_switches_for("deploy_ex.load_test.init"), do: MapSet.new([])
  defp task_switches_for("terraform.create_state_bucket"), do: MapSet.new([])
  defp task_switches_for("terraform.create_state_lock_table"), do: MapSet.new([])
  defp task_switches_for("terraform.drop_state_bucket"), do: MapSet.new([])
  defp task_switches_for("terraform.drop_state_lock_table"), do: MapSet.new([])

  defp task_switches_for(task) do
    path = Path.join(@tasks_dir, "#{task}.ex")
    source = File.read!(path)
    ast = Code.string_to_quoted!(source)

    switches =
      ast
      |> find_option_parser_switches()
      |> List.first() ||
        flunk("could not find OptionParser switches for #{task} in #{path}")

    Enum.into(switches, MapSet.new(), fn {key, _type} -> key end)
  end

  defp find_option_parser_switches(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:OptionParser]}, parser]}, _, [_args, opts]} = node, acc
        when parser in [:parse, :parse!] and is_list(opts) ->
          case Keyword.get(opts, :switches) do
            nil -> {node, acc}
            switches when is_list(switches) -> {node, [switches | acc]}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp format_mismatches(mismatches) do
    lines =
      Enum.map(mismatches, fn {task, missing, extra} ->
        "  #{task}: missing from wizard #{inspect(missing)}, phantom in wizard #{inspect(extra)}"
      end)

    "wizard registry drifted from task OptionParser switches:\n" <> Enum.join(lines, "\n")
  end
end
