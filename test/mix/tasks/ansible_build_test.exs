defmodule Mix.Tasks.Ansible.BuildTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ansible.Build

  describe "ansible_group_vars_enabled_flags/1" do
    test "is_sentry_enabled is true by default" do
      assert Build.ansible_group_vars_enabled_flags([])[:is_sentry_enabled] === true
    end

    test "is_sentry_enabled is false when no_sentry is set" do
      assert Build.ansible_group_vars_enabled_flags(no_sentry: true)[:is_sentry_enabled] === false
    end

    test "is_logging_enabled and is_prometheus_enabled default to true" do
      flags = Build.ansible_group_vars_enabled_flags([])

      assert flags[:is_logging_enabled] === true
      assert flags[:is_prometheus_enabled] === true
    end
  end
end
