defmodule DeployEx.QaPlaybook do
  @moduledoc """
  Throwaway per-QA-node Ansible playbook generation.

  QA nodes are ephemeral and their ansible context is dynamic (which node, which
  branch, which cert mode). Rather than encode that in a shared playbook or a
  monster `--extra-vars` CLI string, we generate a one-shot wrapper at
  `<ansible_dir>/.qa_tmp/<instance_id>-<kind>.yml` that `import_playbook`s the
  shared setup/deploy play and pins the QA-specific vars at the import boundary.

  The wrapper is written, invoked by the caller's callback, and deleted — even
  when the callback raises or the ansible run fails.
  """

  @tmp_dir ".qa_tmp"
  @gitignore_body "*\n!.gitignore\n"

  @type kind :: :setup | :deploy

  @doc """
  Generates a temp QA playbook, invokes `callback` with the relative path to
  it (rooted at `ansible_dir`), and cleans up afterward.

  The callback is expected to run `ansible-playbook <rel_path>` itself — we
  stay out of the invocation so call sites can add their own flags (`--limit`,
  etc).

  Vars with `nil` or empty-string values are dropped from the wrapper so the
  shared playbook's own defaults can take over.
  """
  @spec with_temp_playbook(
          DeployEx.QaNode.t(),
          kind(),
          keyword(),
          String.t(),
          (String.t() -> any())
        ) :: any()
  def with_temp_playbook(%DeployEx.QaNode{} = qa_node, kind, vars, ansible_dir, callback)
      when kind in [:setup, :deploy] and is_list(vars) and is_binary(ansible_dir) and
             is_function(callback, 1) do
    ensure_tmp_dir!(ansible_dir)
    DeployEx.AnsibleRoles.sync(ansible_dir)

    rel_path = Path.join(@tmp_dir, "#{qa_node.instance_id}-#{kind}.yml")
    abs_path = Path.join(ansible_dir, rel_path)

    File.write!(abs_path, render_playbook(qa_node, kind, vars))

    try do
      callback.(rel_path)
    after
      _ = File.rm(abs_path)
    end
  end

  @doc false
  def render_playbook(%DeployEx.QaNode{} = qa_node, kind, vars) when kind in [:setup, :deploy] do
    shared = shared_playbook(kind, qa_node.app_name)
    rendered = render_vars(vars)

    if rendered === "" do
      """
      ---
      - import_playbook: #{shared}
      """
    else
      """
      ---
      - import_playbook: #{shared}
        vars:
      #{rendered}
      """
    end
  end

  defp shared_playbook(:setup, app_name), do: "../setup/#{app_name}.yaml"
  defp shared_playbook(:deploy, app_name), do: "../playbooks/#{app_name}.yaml"

  defp render_vars(vars) do
    vars
    |> Enum.filter(fn {_k, v} -> not blank?(v) end)
    |> Enum.map_join("\n", fn {k, v} -> "    #{k}: #{yaml_value(v)}" end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp yaml_value(v) when is_boolean(v), do: to_string(v)
  defp yaml_value(v) when is_integer(v), do: to_string(v)
  defp yaml_value(v) when is_binary(v), do: ~s("#{String.replace(v, "\"", "\\\"")}")

  defp ensure_tmp_dir!(ansible_dir) do
    dir = Path.join(ansible_dir, @tmp_dir)
    File.mkdir_p!(dir)

    gitignore = Path.join(dir, ".gitignore")
    unless File.exists?(gitignore), do: File.write!(gitignore, @gitignore_body)
  end
end
