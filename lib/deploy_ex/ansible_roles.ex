defmodule DeployEx.AnsibleRoles do
  @moduledoc """
  Syncs `deploy_ex`-managed Ansible roles from the library's `priv/ansible/roles/`
  into the user project's `deploys/ansible/roles/` at the start of ansible
  operations, so role fixes in new deploy_ex versions propagate without the
  user having to re-run `mix ansible.build`.

  Roles under `priv/ansible/roles/` are owned by deploy_ex — any user
  modifications there get overwritten on sync. Projects that need custom
  behavior should add their own separately-named roles alongside.
  """

  @doc """
  Copies every role directory from deploy_ex's priv tree into the target
  ansible directory. No-op when either side is missing. Returns `:ok` in all
  non-exceptional cases; callers can ignore the result.

  Goes straight to `:code.priv_dir/1` rather than `DeployExHelpers.priv_folder/1`
  — the latter prefers the user project's local `deploys/` copy and would
  cause this sync to overwrite itself with stale files.
  """
  @spec sync(String.t()) :: :ok
  def sync(ansible_dir) when is_binary(ansible_dir) do
    priv_roles = :deploy_ex |> :code.priv_dir() |> Path.join("ansible/roles")
    target_roles = Path.join(ansible_dir, "roles")

    if File.dir?(priv_roles) and File.dir?(target_roles) do
      File.cp_r!(priv_roles, target_roles)
    end

    :ok
  end
end
