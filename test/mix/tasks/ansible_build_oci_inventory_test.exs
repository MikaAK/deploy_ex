defmodule Mix.Tasks.Ansible.Build.OciInventoryTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ansible.Build

  # These exercise the PURE transform from hydrated OCI instances (already fetched from the
  # oci CLI, see Build.fetch_oci_instances/1) to inventory host entries — no live oci CLI or
  # network access, so this covers the group/hostvar contract hermetically.

  defp instance(overrides) do
    Map.merge(
      %{
        id: "ocid1.instance.oc1.ap-seoul-1.example",
        name: "dx-ansible-test-01",
        tags: %{"Group" => "Deploy Ex Backend", "InstanceGroup" => "deploy_ex_basic_dev"},
        public_ip: "64.110.76.187",
        private_ip: "10.60.0.183",
        ipv6: nil
      },
      overrides
    )
  end

  describe "oci_inventory_hosts/1" do
    test "composes hostname as <instance-id>-<Name tag>" do
      [host] = Build.oci_inventory_hosts([instance(%{})])

      assert host.hostname === "ocid1.instance.oc1.ap-seoul-1.example-dx-ansible-test-01"
    end

    test "ansible_host prefers ipv6, then public_ip, then private_ip" do
      [ipv6_host] = Build.oci_inventory_hosts([instance(%{ipv6: "fe80::1"})])
      [public_host] = Build.oci_inventory_hosts([instance(%{})])
      [private_host] = Build.oci_inventory_hosts([instance(%{public_ip: nil})])

      assert ipv6_host.vars.ansible_host === "fe80::1"
      assert public_host.vars.ansible_host === "64.110.76.187"
      assert private_host.vars.ansible_host === "10.60.0.183"
    end

    test "composes the seven tag-derived hostvars for a non-qa host" do
      [host] = Build.oci_inventory_hosts([instance(%{})])

      assert host.vars.release_prefix === ""
      assert host.vars.release_state_prefix === "release-state"
      assert host.vars.git_branch === ""
      assert host.vars.qa_node === false
      assert host.vars.qa_node_suffix === ""
      assert host.vars.instance_tag === ""
      assert host.vars.letsencrypt_use_public_ip === false
    end

    test "QaNode=true flips the qa-derived hostvars together" do
      tags = %{"Group" => "Deploy Ex Backend", "QaNode" => "true", "GitBranch" => "feature/x"}
      [host] = Build.oci_inventory_hosts([instance(%{tags: tags})])

      assert host.vars.release_prefix === "qa"
      assert host.vars.release_state_prefix === "release-state/qa"
      assert host.vars.qa_node === true
      assert host.vars.qa_node_suffix === "_qa"
      assert host.vars.git_branch === "feature/x"
    end

    test "UsePublicIpCert=true sets letsencrypt_use_public_ip" do
      tags = %{"Group" => "Deploy Ex Backend", "UsePublicIpCert" => "true"}
      [host] = Build.oci_inventory_hosts([instance(%{tags: tags})])

      assert host.vars.letsencrypt_use_public_ip === true
    end

    test "keyed groups come from MonitoringKey/InstanceGroup/DatabaseKey/QaNode tags only" do
      tags = %{
        "Group" => "Deploy Ex Backend",
        "InstanceGroup" => "deploy_ex_basic_dev",
        "MonitoringKey" => "prometheus_db",
        "DatabaseKey" => "deploy_ex_redis",
        "QaNode" => "true",
        "SomeOtherTag" => "ignored"
      }

      [host] = Build.oci_inventory_hosts([instance(%{tags: tags})])

      expected = ["group_deploy_ex_basic_dev", "monitoring_prometheus_db", "database_deploy_ex_redis", "qa_true"]

      assert Enum.sort(host.groups) === Enum.sort(expected)
    end

    test "a tag with no value contributes no group" do
      [host] = Build.oci_inventory_hosts([instance(%{tags: %{"Group" => "Deploy Ex Backend"}})])

      assert host.groups === []
    end
  end

  describe "render_oci_hosts_section/1" do
    test "renders {} for an empty host list" do
      assert Build.render_oci_hosts_section([]) === "  hosts: {}"
    end

    test "renders one indented block per host with every hostvar" do
      [host] = Build.oci_inventory_hosts([instance(%{})])

      rendered = Build.render_oci_hosts_section([host])

      assert rendered =~ "  hosts:\n"
      assert rendered =~ "    ocid1.instance.oc1.ap-seoul-1.example-dx-ansible-test-01:\n"
      assert rendered =~ "      ansible_host: \"64.110.76.187\""
      assert rendered =~ "      qa_node: false"
    end
  end

  describe "render_oci_children_section/1" do
    test "renders {} when no host belongs to any group" do
      [host] = Build.oci_inventory_hosts([instance(%{tags: %{"Group" => "Deploy Ex Backend"}})])

      assert Build.render_oci_children_section([host]) === "  children: {}"
    end

    test "groups hosts under their keyed group name" do
      tags = %{"Group" => "Deploy Ex Backend", "InstanceGroup" => "deploy_ex_basic_dev"}
      [host] = Build.oci_inventory_hosts([instance(%{tags: tags})])

      rendered = Build.render_oci_children_section([host])

      assert rendered =~ "  children:\n"
      assert rendered =~ "    group_deploy_ex_basic_dev:\n      hosts:\n"
      assert rendered =~ "        ocid1.instance.oc1.ap-seoul-1.example-dx-ansible-test-01: {}"
    end
  end
end
