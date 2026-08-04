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
  end
end
