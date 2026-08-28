defmodule Mix.Tasks.Terraform.BuildTest do
  use ExUnit.Case, async: true

  # terraform_redis_variables/1, terraform_loki_variables/1, terraform_grafana_variables/1,
  # and terraform_prometheus_variables/1 are private and only reachable through run/1, which
  # performs live AWS/terraform side effects. We instead assert against the literal heredoc
  # text shipped in this module's source, which is exactly what write_terraform_template_files/2
  # interpolates into variables.tf. See test/deploy_ex/priv_renderer_test.exs for the
  # equivalent assertions against the actually-rendered output of the mirrored functions in
  # lib/deploy_ex/priv_renderer.ex.

  @source_path Path.join([__DIR__, "..", "..", "..", "lib", "mix", "tasks", "terraform.build.ex"])

  describe "terraform_redis_variables/1 heredoc" do
    test "uses nested ebs form with secondary_size 16" do
      block = fetch_block("terraform_redis_variables", "terraform_sentry_variables")

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*16/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "pins instance_availability_zone from opts and drops the fixed private_ip" do
      block = fetch_block("terraform_redis_variables", "terraform_sentry_variables")

      assert block =~ ~S(instance_availability_zone = "#{opts[:availability_zone]}")
      refute block =~ "private_ip"
    end
  end

  describe "terraform_sentry_variables/1 heredoc" do
    test "pins instance_availability_zone from opts" do
      block = fetch_block("terraform_sentry_variables", "terraform_loki_variables")

      assert block =~ ~S(instance_availability_zone = "#{opts[:availability_zone]}")
      refute block =~ "private_ip"
    end
  end

  describe "terraform_loki_variables/1 heredoc" do
    test "uses nested ebs form with secondary_size 8" do
      block = fetch_block("terraform_loki_variables", "terraform_grafana_variables")

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*8/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "pins instance_availability_zone from opts and drops the fixed private_ip" do
      block = fetch_block("terraform_loki_variables", "terraform_grafana_variables")

      assert block =~ ~S(instance_availability_zone = "#{opts[:availability_zone]}")
      refute block =~ "private_ip"
    end
  end

  describe "terraform_grafana_variables/1 heredoc" do
    test "uses nested ebs form with secondary_size 8, enable_eip untouched" do
      block = fetch_block("terraform_grafana_variables", "terraform_prometheus_variables")

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*8/
      assert block =~ ~r/enable_eip\s*=\s*true/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "pins instance_availability_zone from opts" do
      block = fetch_block("terraform_grafana_variables", "terraform_prometheus_variables")

      assert block =~ ~S(instance_availability_zone = "#{opts[:availability_zone]}")
    end
  end

  describe "terraform_prometheus_variables/1 heredoc" do
    test "uses nested ebs form with secondary_size 16" do
      block = fetch_block("terraform_prometheus_variables", "generate_db_password")

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*16/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "pins instance_availability_zone from opts and drops the fixed private_ip" do
      block = fetch_block("terraform_prometheus_variables", "generate_db_password")

      assert block =~ ~S(instance_availability_zone = "#{opts[:availability_zone]}")
      refute block =~ "private_ip"
    end
  end

  describe "build_opts/1 — availability_zone (behavioral, not source-regex)" do
    # build_opts/1 is the same opts pipeline run/1 feeds into every
    # terraform_*_variables/1 call — testing it directly (rather than only
    # grepping source) proves the actual value threaded through opts, not
    # just that some matching text exists somewhere in the file.

    test "defaults opts[:availability_zone] from opts[:aws_region] when no CLI flag is given" do
      opts = Mix.Tasks.Terraform.Build.build_opts(["--aws-region", "us-east-1"])

      assert opts[:availability_zone] === "us-east-1a"
    end

    test "--availability-zone overrides the region-derived default" do
      opts = Mix.Tasks.Terraform.Build.build_opts(["--aws-region", "us-east-1", "--availability-zone", "us-east-1c"])

      assert opts[:availability_zone] === "us-east-1c"
    end
  end

  defp fetch_block(start_function_name, end_function_name) do
    source = File.read!(@source_path)
    regex = Regex.compile!("defp #{start_function_name}\\(opts\\) do(.*?)defp #{end_function_name}", "s")

    case Regex.run(regex, source) do
      [_full, block] -> block
      nil -> flunk("could not locate #{start_function_name} in #{@source_path}")
    end
  end
end
