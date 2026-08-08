defmodule Mix.Tasks.Terraform.BuildRenderTest do
  # async: false — drives a real Mix task and writes to the filesystem
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Terraform.Build

  setup do
    dirs = Enum.map(1..2, fn index ->
      Path.join(System.tmp_dir!(), "p00_tf_#{System.unique_integer([:positive])}_#{index}")
    end)

    on_exit(fn -> Enum.each(dirs, &File.rm_rf!/1) end)

    {:ok, dirs: dirs}
  end

  defp render(args), do: capture_io(fn -> Build.run(args) end)

  defp key_pair_contents(dir), do: File.read!(Path.join(dir, "key-pair-main.tf"))

  describe "--render-dir" do
    test "renders the terraform set into a fresh directory", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      assert File.dir?(dir)

      for file <- ~w(variables.tf ec2.tf providers.tf key-pair-main.tf outputs.tf database.tf) do
        assert File.exists?(Path.join(dir, file)), "expected #{file} in render dir"
      end
    end

    test "leaves no .eex templates behind", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      assert Path.wildcard(Path.join(dir, "**/*.eex")) === []
    end

    test "skips terraform init", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--quiet"])

      refute File.exists?(Path.join(dir, ".terraform"))
    end

    test "writes nothing outside the render dir", %{dirs: [dir | _]} do
      deploys_before = File.exists?("./deploys")

      render(["--render-dir", dir, "--quiet"])

      assert File.exists?("./deploys") === deploys_before
    end
  end

  describe "--pem-app-name" do
    test "two runs with the same pinned name render identical bytes", %{dirs: [one, two]} do
      render(["--render-dir", one, "--pem-app-name", "pinned-abc", "--quiet"])
      render(["--render-dir", two, "--pem-app-name", "pinned-abc", "--quiet"])

      assert key_pair_contents(one) === key_pair_contents(two)
    end

    test "two runs with different pinned names render different bytes", %{dirs: [one, two]} do
      render(["--render-dir", one, "--pem-app-name", "pinned-abc", "--quiet"])
      render(["--render-dir", two, "--pem-app-name", "other-xyz", "--quiet"])

      assert key_pair_contents(one) !== key_pair_contents(two)
    end

    test "without the flag the pem name stays random per run", %{dirs: [one, two]} do
      render(["--render-dir", one, "--quiet"])
      render(["--render-dir", two, "--quiet"])

      assert key_pair_contents(one) !== key_pair_contents(two)
    end
  end

  describe "--db-password" do
    test "is accepted and the run completes", %{dirs: [dir | _]} do
      render(["--render-dir", dir, "--db-password", "pinnedpw", "--quiet"])

      assert File.exists?(Path.join(dir, "database.tf"))
    end
  end
end
