defmodule DeployEx.DeployNodeReleaseStateTest do
  use ExUnit.Case, async: true

  # The release-state files in S3 (`<prefix>/<app>/current_release.txt` and
  # `release_history.txt`) are what `--target-sha current`, `mix ansible.rollback` and
  # `mix deploy_ex.list_app_release_history` read. Recording the new release before the
  # atomic swap made that record a statement of intent rather than of fact: a play that
  # died between the two left S3 naming a release the node was not running. This pins the
  # order — nothing else in the suite covers it, and the two tasks are 30 lines apart.

  @tasks_path Path.expand("../../priv/ansible/roles/deploy_node/tasks/main.yaml", __DIR__)

  @swap_task "- name: Atomic swap into /srv/{{ app_name }} and restart {{ app_name }}"
  @state_task "- name: Update release state for {{ app_name }}"

  setup do
    %{tasks: File.read!(@tasks_path)}
  end

  test "release state is recorded after the atomic swap, not before it", %{tasks: tasks} do
    assert [{swap_index, _length}] = :binary.matches(tasks, @swap_task)
    assert [{state_index, _length}] = :binary.matches(tasks, @state_task)

    assert state_index > swap_index
  end

  test "the state script still receives the key that was actually unpacked", %{tasks: tasks} do
    assert tasks =~
             "cmd: update_release_state.sh {{ bucket_name }} {{ release_state_prefix }} " <>
               "{{ app_name }} {{ s3_object_key }}"
  end
end
