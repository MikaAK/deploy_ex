defmodule Mix.Tasks.Ansible.BuildRenderTest do
  # async: false — drives a real Mix task and writes to the filesystem
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ansible.Build

  setup do
    dirs = Enum.map(1..2, fn index ->
      Path.join(System.tmp_dir!(), "p00_ans_#{System.unique_integer([:positive])}_#{index}")
    end)

    on_exit(fn -> Enum.each(dirs, &File.rm_rf!/1) end)

    {:ok, dirs: dirs}
  end

  defp render(args), do: capture_io(fn -> Build.run(args) end)

  defp file_tree(dir) do
    dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.sort()
  end

  describe "--render-dir" do
    test "renders into a fresh directory without raising", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      assert File.dir?(dir)
    end

    test "renders ansible.cfg with the placeholder pem path", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      config_path = Path.join(dir, "ansible.cfg")

      assert File.exists?(config_path)
      assert File.read!(config_path) =~ "../terraform/RENDER_DIR_PLACEHOLDER.pem"
    end

    test "renders the hosts file and group vars", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      assert File.exists?(Path.join(dir, "aws_ec2.yaml"))
      assert File.exists?(Path.join(dir, "group_vars/all.yaml"))
    end

    test "seeds roles into the render dir", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      assert File.dir?(Path.join(dir, "roles"))
    end

    test "writes playbooks into the render dir", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      assert File.exists?(Path.join(dir, "playbooks/deploy_ex.yaml"))
      assert File.exists?(Path.join(dir, "setup/deploy_ex.yaml"))
    end

    test "removes the copied root templates from the render dir", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      assert Path.wildcard(Path.join(dir, "*.eex")) === []
    end

    test "writes nothing into the live deploys tree", %{dirs: [dir | _]} do
      deploys_before = Path.wildcard("./deploys/**", match_dot: true)

      render(["--render-dir", dir, "--quiet"])

      assert Path.wildcard("./deploys/**", match_dot: true) === deploys_before
    end

    test "two runs render identical trees", %{dirs: [one, two]} do
      render(["--render-dir", one, "--quiet"])
      render(["--render-dir", two, "--quiet"])

      assert file_tree(one) === file_tree(two)

      for relative_path <- file_tree(one), File.regular?(Path.join(one, relative_path)) do
        assert File.read!(Path.join(one, relative_path)) ===
                 File.read!(Path.join(two, relative_path)),
               "#{relative_path} differed between runs"
      end
    end

    test "the default aws render carries zero provider-scoped files", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      refute File.dir?(Path.join(dir, "providers"))
      refute File.exists?(Path.join(dir, "oci.yaml"))
    end
  end

  describe "--provider" do
    test "an unknown provider raises a clear error", %{dirs: [dir | _]} do
      assert_raise Mix.Error, ~r/unknown provider "unknown-cloud"/, fn ->
        render(["--render-dir", dir, "--provider", "unknown-cloud", "--quiet"])
      end
    end

    test "oci without a compartment_id raises before touching the oci CLI", %{dirs: [dir | _]} do
      assert_raise Mix.Error, ~r/compartment_id is required/, fn ->
        render(["--render-dir", dir, "--provider", "oci", "--quiet"])
      end
    end

    test "oci --auto-pull-aws raises instead of silently doing nothing", %{dirs: [dir | _]} do
      assert_raise Mix.Error, ~r/--auto-pull-aws only supports the aws provider/, fn ->
        render([
          "--render-dir", dir,
          "--provider", "oci",
          "--auto-pull-aws",
          "--oci-compartment-id", "ocid1.compartment.oc1..fake",
          "--quiet"
        ])
      end
    end
  end

  describe "DeployEx.Cloud.PrivFileSet file selection" do
    setup do
      {:ok, priv_path: DeployExHelpers.priv_folder("ansible")}
    end

    test "aws never resolves the oci-scoped templates", %{priv_path: priv_path} do
      {:ok, files} = DeployEx.Cloud.PrivFileSet.files(:aws, priv_path)
      dests = Enum.map(files, fn {_source, dest} -> dest end)

      refute "oci.yaml.eex" in dests
      refute Enum.any?(dests, &String.starts_with?(&1, "providers/"))
    end

    test "oci resolves ansible.cfg.eex and oci.yaml.eex flattened, and nothing aws-only", %{priv_path: priv_path} do
      {:ok, files} = DeployEx.Cloud.PrivFileSet.files(:oci, priv_path)

      assert {"providers/oci/ansible.cfg.eex", "ansible.cfg.eex"} in files
      assert {"providers/oci/oci.yaml.eex", "oci.yaml.eex"} in files
      refute Enum.any?(files, fn {source, _dest} -> source === "aws_ec2.yaml.eex" end)
    end
  end

  describe "the oci ansible.cfg template" do
    test "sets the ubuntu remote user, the oci.yaml inventory, and no [inventory] plugin section" do
      contents = "ansible/providers/oci/ansible.cfg.eex" |> DeployExHelpers.priv_folder() |> File.read!()

      assert contents =~ "remote_user = ubuntu"
      assert contents =~ "inventory = ./oci.yaml"
      refute contents =~ "[inventory]"
      refute contents =~ "enable_plugins"
    end
  end
end
