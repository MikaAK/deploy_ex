defmodule DeployEx.PrivRendererTest do
  use ExUnit.Case, async: true

  alias DeployEx.PrivRenderer

  setup do
    on_exit(fn ->
      # Clean up any temp dirs left behind by failed tests
      :ok
    end)

    :ok
  end

  describe "render_to_temp/1" do
    test "returns {:ok, temp_dir} where temp_dir exists" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      assert File.exists?(temp_dir)
      assert File.dir?(temp_dir)
    end

    test "temp dir contains rendered terraform files without .eex extension" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      terraform_dir = Path.join(temp_dir, "terraform")
      assert File.dir?(terraform_dir)

      # Rendered files should exist without .eex
      assert File.exists?(Path.join(terraform_dir, "variables.tf"))
      assert File.exists?(Path.join(terraform_dir, "ec2.tf"))
      assert File.exists?(Path.join(terraform_dir, "providers.tf"))
      assert File.exists?(Path.join(terraform_dir, "key-pair-main.tf"))
      assert File.exists?(Path.join(terraform_dir, "outputs.tf"))
      assert File.exists?(Path.join(terraform_dir, "database.tf"))

      # No .eex files should remain
      eex_files = Path.join(terraform_dir, "*.eex") |> Path.wildcard()
      assert Enum.empty?(eex_files)
    end

    test "temp dir contains static terraform modules" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      modules_dir = Path.join(temp_dir, "terraform/modules")
      assert File.dir?(modules_dir)
      assert File.dir?(Path.join(modules_dir, "aws-instance"))
      assert File.exists?(Path.join(modules_dir, "aws-instance/main.tf"))
      assert File.dir?(Path.join(modules_dir, "aws-database"))
    end

    test "temp dir contains static terraform files" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      terraform_dir = Path.join(temp_dir, "terraform")
      assert File.exists?(Path.join(terraform_dir, "network.tf"))
      assert File.exists?(Path.join(terraform_dir, "bucket.tf"))
      assert File.exists?(Path.join(terraform_dir, "iam.tf"))
    end

    test "temp dir contains ansible roles" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      ansible_dir = Path.join(temp_dir, "ansible")
      assert File.dir?(ansible_dir)
      assert File.dir?(Path.join(ansible_dir, "roles"))
      assert File.dir?(Path.join(ansible_dir, "roles/elixir_runner"))
    end

    test "temp dir contains rendered ansible config files" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      ansible_dir = Path.join(temp_dir, "ansible")
      assert File.exists?(Path.join(ansible_dir, "ansible.cfg"))
      assert File.exists?(Path.join(ansible_dir, "aws_ec2.yaml"))
      assert File.exists?(Path.join(ansible_dir, "group_vars/all.yaml"))

      # No .eex files should remain in ansible root
      eex_files = Path.join(ansible_dir, "*.eex") |> Path.wildcard()
      assert Enum.empty?(eex_files)
    end

    test "rendered terraform files contain valid content" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      variables_content = Path.join(temp_dir, "terraform/variables.tf") |> File.read!()
      assert variables_content =~ "variable"
      assert variables_content =~ "environment"
    end

    test "rendered ansible config contains expected structure" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      config_content = Path.join(temp_dir, "ansible/ansible.cfg") |> File.read!()
      assert config_content =~ "[defaults]"
      assert config_content =~ "remote_user"
    end

    test "temp dir contains ansible setup playbooks" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      ansible_dir = Path.join(temp_dir, "ansible")
      assert File.dir?(Path.join(ansible_dir, "setup"))
    end

    test "each call creates a unique temp dir" do
      assert {:ok, dir1} = PrivRenderer.render_to_temp()
      assert {:ok, dir2} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(dir1); File.rm_rf!(dir2) end)

      refute dir1 === dir2
    end

    test "variables.tf includes the completed sentry node by default" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      variables_content = Path.join(temp_dir, "terraform/variables.tf") |> File.read!()

      assert variables_content =~ "sentry = {"
      assert variables_content =~ ~s(instance_type = "t3.large")
      assert variables_content =~ ~s(private_ip    = "10.0.1.70")
      assert variables_content =~ ~s(MonitoringKey = "sentry")
    end

    test "variables.tf omits the sentry node when no_sentry: true" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp(no_sentry: true)
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      variables_content = Path.join(temp_dir, "terraform/variables.tf") |> File.read!()

      refute variables_content =~ "sentry = {"
    end

    test "group_vars/all.yaml includes sentry_url at the sentry node's private_ip by default" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      group_vars_content = Path.join(temp_dir, "ansible/group_vars/all.yaml") |> File.read!()

      assert group_vars_content =~ ~s(sentry_url: "http://10.0.1.70:9000")
    end

    test "group_vars/all.yaml omits sentry_url when no_sentry: true" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp(no_sentry: true)
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      group_vars_content = Path.join(temp_dir, "ansible/group_vars/all.yaml") |> File.read!()

      refute group_vars_content =~ "sentry_url"
    end
  end

  describe "render_to_temp/1 - ebs nested form" do
    setup do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      variables_content = temp_dir |> Path.join("terraform/variables.tf") |> File.read!()

      {:ok, variables_content: variables_content}
    end

    test "redis block uses nested ebs form with secondary_size 16", %{variables_content: variables_content} do
      block = fetch_block(variables_content, ~r/\w*_redis\s*=\s*\{.*?\n\s*\},/s)

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*16/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "loki block uses nested ebs form with secondary_size 8", %{variables_content: variables_content} do
      block = fetch_block(variables_content, ~r/loki_aggregator\s*=\s*\{.*?\n\s*\},/s)

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*8/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "grafana block uses nested ebs form with secondary_size 8, enable_eip untouched", %{variables_content: variables_content} do
      block = fetch_block(variables_content, ~r/grafana_ui\s*=\s*\{.*?\n\s*\},/s)

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*8/
      assert block =~ ~r/enable_eip\s*=\s*true/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "prometheus block uses nested ebs form with secondary_size 16", %{variables_content: variables_content} do
      block = fetch_block(variables_content, ~r/prometheus_db\s*=\s*\{.*?\n\s*\},/s)

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*16/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end
  end

  describe "render_to_temp/1 - DHCP + shared AZ pin" do
    setup do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      variables_content = temp_dir |> Path.join("terraform/variables.tf") |> File.read!()

      {:ok, variables_content: variables_content}
    end

    @monitoring_block_regexes %{
      redis: ~r/\w*_redis\s*=\s*\{.*?\n\s*\},/s,
      sentry: ~r/\bsentry\s*=\s*\{.*?\n\s*\},/s,
      loki: ~r/loki_aggregator\s*=\s*\{.*?\n\s*\},/s,
      grafana: ~r/grafana_ui\s*=\s*\{.*?\n\s*\},/s,
      prometheus: ~r/prometheus_db\s*=\s*\{.*?\n\s*\},/s,
      mimir: ~r/mimir_db\s*=\s*\{.*?\n\s*\},/s
    }

    for {name, _regex} <- @monitoring_block_regexes do
      test "#{name} block has no fixed private_ip", %{variables_content: variables_content} do
        block = fetch_block(variables_content, @monitoring_block_regexes[unquote(name)])

        refute block =~ "private_ip"
      end
    end

    test "every monitoring/DB block pins the exact same instance_availability_zone",
         %{variables_content: variables_content} do
      zones =
        Enum.map(@monitoring_block_regexes, fn {name, regex} ->
          block = fetch_block(variables_content, regex)
          [zone] = Regex.run(~r/instance_availability_zone\s*=\s*"([^"]+)"/, block, capture: :all_but_first)
          {name, zone}
        end)

      distinct_zones = zones |> Enum.map(fn {_name, zone} -> zone end) |> Enum.uniq()

      assert length(distinct_zones) === 1, "expected one shared AZ across all blocks, got: #{inspect(zones)}"
      assert distinct_zones === [DeployEx.Config.aws_availability_zone()]
    end

    test "a consumer-supplied :availability_zone opt propagates to every block" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp(availability_zone: "us-east-1c")
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      variables_content = temp_dir |> Path.join("terraform/variables.tf") |> File.read!()

      Enum.each(@monitoring_block_regexes, fn {_name, regex} ->
        block = fetch_block(variables_content, regex)
        assert block =~ ~s(instance_availability_zone = "us-east-1c")
      end)
    end
  end

  defp fetch_block(content, regex) do
    case Regex.run(regex, content) do
      [block] -> block
      nil -> flunk("could not locate block matching #{inspect(regex)} in:\n#{content}")
    end
  end
end
