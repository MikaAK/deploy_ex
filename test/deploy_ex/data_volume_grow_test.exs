defmodule DeployEx.DataVolumeGrowTest do
  use ExUnit.Case, async: true

  # docs/superpowers/plans/d5-backlog/mount-mechanism.md — item D. xfs_growfs
  # runs only inside cloud-init's prepare-ebs-volume.sh, i.e. once per
  # instance birth, so growing an EBS volume afterwards never resizes the
  # filesystem (a live node was found sitting on a 32 GiB filesystem on a
  # 64 GiB volume). This role makes the grow happen on every converge,
  # dispatching by the filesystem actually detected on /data — the same
  # xfs_growfs / resize2fs split prepare-ebs-volume.sh already uses — and
  # does no formatting, mounting, or fstab work, so it cannot fight
  # cloud-init's mkfs-or-preserve logic.
  #
  # Raw content assertions, same exemption/pattern as
  # test/deploy_ex/mimir_role_test.exs (Ansible/Jinja content, not
  # Elixir-rendered).

  @priv_ansible_dir Path.expand("../../priv/ansible", __DIR__)
  @setup_dir Path.join(@priv_ansible_dir, "setup")
  @role_dir Path.join(@priv_ansible_dir, "roles/data_volume_grow")

  @playbooks_using_data [
    {"prometheus_db.yaml.eex", Path.join(@setup_dir, "prometheus_db.yaml.eex")},
    {"mimir_db.yaml", Path.join(@setup_dir, "mimir_db.yaml")},
    {"loki_log_aggregator.yaml.eex", Path.join(@setup_dir, "loki_log_aggregator.yaml.eex")},
    {"redis.yaml", Path.join(@setup_dir, "redis.yaml")}
  ]

  defp role_tasks, do: File.read!(Path.join(@role_dir, "tasks/main.yaml"))

  # SECTION: every playbook with a /data volume grows it on converge

  describe "playbooks with a /data volume — data_volume_grow included" do
    for {name, path} <- @playbooks_using_data do
      test "#{name} includes the data_volume_grow role" do
        content = File.read!(unquote(path))

        assert content =~ "- data_volume_grow"
      end
    end
  end

  # SECTION: the role's grow logic — same fstype dispatch as prepare-ebs-volume.sh

  describe "data_volume_grow role — task structure" do
    test "detects the filesystem type from /data itself, not a hardcoded assumption" do
      assert role_tasks() =~ "findmnt -no FSTYPE /data"
    end

    test "grows xfs via xfs_growfs, guarded by the detected filesystem type" do
      content = role_tasks()

      assert content =~ "xfs_growfs /data"
      assert content =~ ~r/when:.*xfs/
    end

    test "grows ext-family filesystems via resize2fs, guarded by the detected filesystem type" do
      content = role_tasks()

      assert content =~ "resize2fs"
      assert content =~ ~r/when:.*ext4/
    end

    test "carries no mkfs, mount, or fstab operation — growth only" do
      content = role_tasks()

      refute content =~ "mkfs"
      refute content =~ "fstab"
      refute content =~ ~r/state:\s*mounted/
    end
  end
end
