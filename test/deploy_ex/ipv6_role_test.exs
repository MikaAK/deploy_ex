defmodule DeployEx.Ipv6RoleTest do
  use ExUnit.Case, async: true

  # priv/ansible/roles/ipv6 is Ansible/Jinja content, not Elixir-rendered — covered
  # here via structural assertions on the parsed YAML task list (same exemption/
  # pattern as test/deploy_ex/grafana_alloy_role_test.exs and mimir_role_test.exs).
  #
  # MEASURED (D5 backlog, AWS-CONFIG-DIR): the role writes `dest: ~/.aws/config`
  # under a block-level `become: true`, so the real path is /root/.aws/config. No
  # role anywhere creates that parent directory — ansible.builtin.copy does not
  # create missing parents, so every setup playbook that runs this role (every app
  # setup playbook, plus grafana_ui, prometheus_db, loki_log_aggregator) fails with
  # "Destination directory /root/.aws does not exist".
  #
  # This suite pins: a directory-creation task exists for /root/.aws, it runs
  # BEFORE the config copy (order, not mere presence — a directory task placed
  # after the copy is useless), it resolves to become: true through block
  # inheritance, and its mode does not grant world access.

  @priv_roles_dir Path.expand("../../priv/ansible/roles", __DIR__)
  @ipv6_role_dir Path.join(@priv_roles_dir, "ipv6")

  defp tasks_main_yaml do
    YamlElixir.read_from_file!(Path.join(@ipv6_role_dir, "tasks/main.yaml"))
  end

  # Ansible resolves `become` per entry, inheriting it from an enclosing block —
  # same resolution rule as grafana_alloy_role_test.exs's privileged_entries/2.
  defp flatten_with_become(entries, inherited_become) do
    Enum.flat_map(entries, fn
      %{"block" => block} = entry ->
        flatten_with_become(block, Map.get(entry, "become", inherited_become))

      entry ->
        [{entry, Map.get(entry, "become", inherited_become)}]
    end)
  end

  defp aws_config_dir_task?({task, _become}) do
    match?(%{"ansible.builtin.file" => %{"path" => "/root/.aws", "state" => "directory"}}, task)
  end

  defp aws_config_copy_task?({task, _become}) do
    get_in(task, ["ansible.builtin.copy", "dest"]) === "~/.aws/config"
  end

  # SECTION: directory task exists and precedes the config copy (order, not presence)

  describe "ipv6 role — /root/.aws parent directory" do
    test "a directory task for /root/.aws runs before the boto config copy" do
      indexed = tasks_main_yaml() |> flatten_with_become(false) |> Enum.with_index()

      dir_indices = for {entry, index} <- indexed, aws_config_dir_task?(entry), do: index
      copy_indices = for {entry, index} <- indexed, aws_config_copy_task?(entry), do: index

      assert [dir_index] = dir_indices
      assert [copy_index] = copy_indices
      assert dir_index < copy_index
    end

    test "the directory task resolves to become: true through block inheritance" do
      indexed = tasks_main_yaml() |> flatten_with_become(false)

      assert [{_task, become}] = Enum.filter(indexed, &aws_config_dir_task?/1)
      assert become === true
    end

    test "the directory task's mode does not grant world access" do
      indexed = tasks_main_yaml() |> flatten_with_become(false)

      assert [{task, _become}] = Enum.filter(indexed, &aws_config_dir_task?/1)
      mode = get_in(task, ["ansible.builtin.file", "mode"])

      refute is_nil(mode)
      refute String.last(mode) in ["4", "5", "6", "7"]
    end
  end
end
