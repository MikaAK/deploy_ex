defmodule Mix.Tasks.Terraform.BuildOciLbTest do
  # async: false — matches ansible_build_render_test.exs; this file grows render-driven rows
  # in later sprints (S2/S3) alongside these template-content rows
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Terraform.Build

  @load_balancer_tf "terraform/providers/oci/modules/oci-instance/load_balancer.tf"
  @module_outputs_tf "terraform/providers/oci/modules/oci-instance/outputs.tf"
  @module_main_tf "terraform/providers/oci/modules/oci-instance/main.tf"
  @module_variables_tf "terraform/providers/oci/modules/oci-instance/variables.tf"
  @root_variables_tf_eex "terraform/variables.tf.eex"
  @aws_instance_main_tf "terraform/modules/aws-instance/main.tf"
  @root_variables_tf_eex_oci "terraform/providers/oci/variables.tf.eex"

  defp load_balancer_tf, do: @load_balancer_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp module_outputs_tf, do: @module_outputs_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp module_main_tf, do: @module_main_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp module_variables_tf, do: @module_variables_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp root_variables_tf_eex_oci, do: @root_variables_tf_eex_oci |> DeployExHelpers.priv_folder() |> File.read!()

  defp render(args), do: capture_io(fn -> Build.run(args) end)

  defp render_dir do
    Path.join(System.tmp_dir!(), "p00_tf_lb_#{System.unique_integer([:positive])}")
  end

  defp file_tree(dir) do
    dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.sort()
  end

  describe "load_balancer.tf — resource declarations" do
    test "T1: declares all six load-balancer resource types" do
      contents = load_balancer_tf()

      assert contents =~ ~r/resource\s+"oci_core_network_security_group"\s+"load_balancer"/
      assert contents =~ ~r/resource\s+"oci_core_network_security_group_security_rule"/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_network_load_balancer"\s+"main"/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_backend_set"/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_backend"/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_listener"/
      refute contents =~ ~r/"oci_load_balancer_/
    end

    test "T2: the NLB sets is_private = false" do
      assert load_balancer_tf() =~ ~r/is_private\s*=\s*false/
    end

    test "T3: backend sets carry policy = FIVE_TUPLE and is_preserve_source = true" do
      contents = load_balancer_tf()

      assert length(Regex.scan(~r/policy\s*=\s*"FIVE_TUPLE"/, contents)) === 2
      assert length(Regex.scan(~r/is_preserve_source\s*=\s*true/, contents)) === 2
    end

    test "T4: seconds->millis conversion uses * 1000 and no hardcoded millisecond literal" do
      contents = load_balancer_tf()

      assert contents =~ ~r/timeout_in_millis\s*=.*\*\s*1000/
      assert contents =~ ~r/interval_in_millis\s*=.*\*\s*1000/
      refute contents =~ ~r/_in_millis\s*=\s*\d/
      assert length(Regex.scan(~r/timeout_in_millis\s*=\s*local\.lb_timeout_in_millis/, contents)) === 2
      assert length(Regex.scan(~r/interval_in_millis\s*=\s*local\.lb_interval_in_millis/, contents)) === 2
      assert contents =~ ~r/lb_timeout_in_millis\s*=\s*var\.load_balancer_health_check_timeout_seconds\s*==\s*null\s*\?\s*null\s*:/
      assert contents =~ ~r/lb_interval_in_millis\s*=\s*var\.load_balancer_health_check_interval_seconds\s*==\s*null\s*\?\s*null\s*:/
      assert length(Regex.scan(~r/retries\s*=\s*var\.load_balancer_health_check_retries/, contents)) === 2
    end

    test "T5: backend-set protocol reads the declared lb_has_path local, defined as != \"\", and falls back to TCP" do
      contents = load_balancer_tf()

      assert contents =~ ~r/lb_has_path\s*=\s*var\.load_balancer_health_check_path\s*!=\s*""/
      assert contents =~ ~r/protocol\s*=\s*local\.lb_has_path\s*\?\s*"HTTP"/
      assert contents =~ ~r/protocol\s*=\s*local\.lb_has_path\s*\?\s*"HTTPS"/
      assert contents =~ ~r/\?\s*"HTTP"\s*:\s*"TCP"/
      assert contents =~ ~r/\?\s*"HTTPS"\s*:\s*"TCP"/
      assert length(Regex.scan(~r/url_path\s*=\s*local\.lb_has_path\s*\?\s*var\.load_balancer_health_check_path\s*:\s*null/, contents)) === 2
      assert contents =~ ~r/return_code\s*=\s*local\.lb_has_path\s*\?\s*coalesce\(var\.load_balancer_health_check_return_code,\s*200\)\s*:\s*null/
      assert contents =~ ~r/return_code\s*=\s*local\.lb_has_path\s*\?\s*coalesce\(var\.load_balancer_health_check_https_return_code,\s*200\)\s*:\s*null/
    end

    test "T6: backend-set and listener names are the unqualified literals http/https" do
      contents = load_balancer_tf()

      assert contents =~ ~r/name\s*=\s*"http"/
      assert contents =~ ~r/name\s*=\s*"https"/
      refute contents =~ ~r/name\s*=\s*"\$\{local\.kebab_instance_name\}-https?"/
    end

    test "T7: NSG rules cover 80 and 443, and the 443 rule is conditional on the https flag" do
      contents = load_balancer_tf()

      assert contents =~ ~r/direction\s*=\s*"INGRESS"/
      assert contents =~ ~r/protocol\s*=\s*"6"/
      assert contents =~ ~r/source\s*=\s*"0\.0\.0\.0\/0"/
      assert contents =~ ~r/min\s*=\s*80(?!\d)/
      assert contents =~ ~r/min\s*=\s*443(?!\d)/
      assert contents =~ ~r/network_security_group_ids\s*=\s*oci_core_network_security_group\.load_balancer\[\*\]\.id/

      assert contents =~ ~r/lb_https_count\s*=\s*var\.enable_load_balancer\s*&&\s*var\.enable_load_balancer_https/

      assert contents =~ ~r/resource\s+"oci_core_network_security_group"\s+"load_balancer"\s*\{\s*count\s*=\s*local\.lb_count\b/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_network_load_balancer"\s+"main"\s*\{\s*count\s*=\s*local\.lb_count\b/
      assert contents =~ ~r/resource\s+"oci_core_network_security_group_security_rule"\s+"load_balancer_http"\s*\{\s*count\s*=\s*local\.lb_count\b/
      assert contents =~ ~r/resource\s+"oci_core_network_security_group_security_rule"\s+"load_balancer_https"\s*\{\s*count\s*=\s*local\.lb_https_count\b/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_backend_set"\s+"http"\s*\{\s*count\s*=\s*local\.lb_count\b/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_backend_set"\s+"https"\s*\{\s*count\s*=\s*local\.lb_https_count\b/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_listener"\s+"http"\s*\{\s*count\s*=\s*local\.lb_count\b/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_listener"\s+"https"\s*\{\s*count\s*=\s*local\.lb_https_count\b/
    end

    test "T20: listener ports are literals 80 and 443, protocol TCP" do
      contents = load_balancer_tf()

      assert contents =~ ~r/resource\s+"oci_network_load_balancer_listener"\s+"http"[\s\S]*?port\s*=\s*80(?!\d)/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_listener"\s+"https"[\s\S]*?port\s*=\s*443(?!\d)/
      assert length(Regex.scan(~r/protocol\s*=\s*"TCP"/, contents)) === 2
    end

    test "T21: backend port matches its set and backend count includes the instance_count factor" do
      contents = load_balancer_tf()

      assert contents =~ ~r/resource\s+"oci_network_load_balancer_backend"\s+"http"\s*\{[^}]*port\s*=\s*80(?!\d)/
      assert contents =~ ~r/resource\s+"oci_network_load_balancer_backend"\s+"https"\s*\{[^}]*port\s*=\s*443(?!\d)/
      assert contents =~ ~r/count\s*=\s*local\.lb_count\s*\*\s*var\.instance_count/
      assert contents =~ ~r/count\s*=\s*local\.lb_https_count\s*\*\s*var\.instance_count/
    end

    test "R1: reserved_ip_ocid is wired as a dynamic reserved_ips block" do
      contents = load_balancer_tf()

      assert contents =~ ~r/dynamic\s+"reserved_ips"/
      assert contents =~ ~r/var\.reserved_ip_ocid\s*==\s*null/
      assert contents =~ ~r/for_each\s*=\s*var\.reserved_ip_ocid\s*==\s*null\s*\?\s*\[\]\s*:\s*\[var\.reserved_ip_ocid\]/
    end
  end

  describe "module outputs.tf — load_balancer_public_ips" do
    test "T9: filters on ip.is_public and never indexes the NLB as [0]" do
      contents = module_outputs_tf()

      assert contents =~ ~r/output\s+"load_balancer_public_ips"/
      assert contents =~ ~r/if\s+ip\.is_public/
      refute contents =~ ~r/network_load_balancer\.main\[0\]/
    end
  end

  describe "module main.tf — nsg_ids never indexes the LB NSG as [0]" do
    test "T8: uses concat + splat, not a bare [0] index" do
      contents = module_main_tf()

      assert contents =~ ~r/nsg_ids\s*=\s*concat\(var\.nsg_ids,\s*oci_core_network_security_group\.load_balancer\[\*\]\.id\)/
      refute contents =~ ~r/oci_core_network_security_group\.load_balancer\[0\]\.id/
    end
  end

  describe "module variables.tf — enable_load_balancer_https default" do
    test "T22: defaults to true, matching AWS's enable_elb_https default" do
      contents = module_variables_tf()

      assert contents =~ ~r/variable\s+"enable_load_balancer_https"\s*\{[\s\S]*?default\s*=\s*true/
    end
  end

  describe "AWS byte-parity regression guard" do
    test "T10: root variables.tf.eex load_balancer block is untouched and aws-instance/main.tf has no oci_ resources" do
      variables_contents = @root_variables_tf_eex |> DeployExHelpers.priv_folder() |> File.read!()
      aws_main_contents = @aws_instance_main_tf |> DeployExHelpers.priv_folder() |> File.read!()

      expected_load_balancer_block = """
    load_balancer = optional(object({
      enable       = optional(bool)
      enable_https = optional(bool)
      colocate_az  = optional(bool)

      port          = optional(number)
      instance_port = optional(number)

      health_check = optional(object({
        path          = optional(string)
        protocol      = optional(string)
        matcher       = optional(string)
        https_matcher = optional(string)

        unhealthy_threshold   = optional(number)
        healthy_threshold     = optional(number)
        timeout  = optional(number)
        interval = optional(number)
      }))
    }))
"""

      assert variables_contents =~ expected_load_balancer_block

      refute variables_contents =~ ~r/return_code\s*=\s*optional\(number\)/
      refute aws_main_contents =~ ~r/oci_/
    end
  end

  describe "PrivFileSet — load_balancer.tf resolves for oci, not aws" do
    setup do
      {:ok, priv_path: DeployExHelpers.priv_folder("terraform")}
    end

    test "T12: oci file set includes load_balancer.tf flattened; aws set has nothing under providers/", %{priv_path: priv_path} do
      {:ok, oci_files} = DeployEx.Cloud.PrivFileSet.files(:oci, priv_path)
      {:ok, aws_files} = DeployEx.Cloud.PrivFileSet.files(:aws, priv_path)

      assert {"providers/oci/modules/oci-instance/load_balancer.tf", "modules/oci-instance/load_balancer.tf"} in oci_files
      refute Enum.any?(aws_files, fn {source, _dest} -> String.starts_with?(source, "providers/") end)
    end
  end

  describe "render — instance.tf wiring and outputs" do
    setup do
      dir = render_dir()
      on_exit(fn -> File.rm_rf!(dir) end)
      render(["--provider", "oci", "--render-dir", dir, "--pem-app-name", "s2-render", "--quiet"])

      {:ok, dir: dir}
    end

    test "T13: instance.tf wires vcn_id and all 8 load_balancer_* keys via try() with the module's own defaults", %{dir: dir} do
      contents = Path.join(dir, "instance.tf") |> File.read!()

      assert contents =~ ~r/^\s*vcn_id\s*=\s*oci_core_vcn\.main\.id/m
      assert contents =~ ~r/^\s*enable_load_balancer\s*=\s*try\(each\.value\.load_balancer\.enable,\s*false\)/m
      assert contents =~ ~r/^\s*enable_load_balancer_https\s*=\s*try\(each\.value\.load_balancer\.enable_https,\s*true\)/m
      assert contents =~ ~r/^\s*load_balancer_health_check_path\s*=\s*try\(each\.value\.load_balancer\.health_check\.path,\s*""\)/m
      assert contents =~ ~r/^\s*load_balancer_health_check_return_code\s*=\s*try\(each\.value\.load_balancer\.health_check\.return_code,\s*null\)/m
      assert contents =~ ~r/^\s*load_balancer_health_check_https_return_code\s*=\s*try\(each\.value\.load_balancer\.health_check\.https_return_code,\s*null\)/m
      assert contents =~ ~r/^\s*load_balancer_health_check_retries\s*=\s*try\(each\.value\.load_balancer\.health_check\.unhealthy_threshold,\s*null\)/m
      assert contents =~ ~r/^\s*load_balancer_health_check_timeout_seconds\s*=\s*try\(each\.value\.load_balancer\.health_check\.timeout,\s*null\)/m
      assert contents =~ ~r/^\s*load_balancer_health_check_interval_seconds\s*=\s*try\(each\.value\.load_balancer\.health_check\.interval,\s*null\)/m
      assert contents =~ ~r/^\s*reserved_ip_ocid\s*=\s*try\(each\.value\.load_balancer\.reserved_ip_ocid,\s*null\)/m
    end

    test "T14: instance.tf wires neither load_balancer.port nor load_balancer.instance_port", %{dir: dir} do
      contents = Path.join(dir, "instance.tf") |> File.read!()

      refute contents =~ ~r/load_balancer\.port\b/
      refute contents =~ ~r/load_balancer\.instance_port\b/
      refute contents =~ ~r/load_balancer\[\s*"(instance_)?port"\s*\]/
    end

    test "T15: outputs.tf exposes load_balancer_public_ips keyed by app, with a description", %{dir: dir} do
      contents = Path.join(dir, "outputs.tf") |> File.read!()

      assert contents =~ ~r/output\s+"load_balancer_public_ips"/
      assert contents =~ ~r/for\s+app,\s*mod\s+in\s+module\.oci_instance\s*:\s*app\s*=>\s*mod\.load_balancer_public_ips/
      assert contents =~ ~r/output\s+"load_balancer_public_ips"\s*\{\s*description\s*=/
    end
  end

  describe "render — aws/oci render sets stay disjoint on load_balancer.tf" do
    test "T11: oci render carries load_balancer.tf; aws render has neither providers/ nor load_balancer.tf" do
      aws_dir = render_dir()
      on_exit(fn -> File.rm_rf!(aws_dir) end)
      render(["--render-dir", aws_dir, "--pem-app-name", "s2-render-aws", "--quiet"])

      oci_dir = render_dir()
      on_exit(fn -> File.rm_rf!(oci_dir) end)
      render(["--provider", "oci", "--render-dir", oci_dir, "--pem-app-name", "s2-render-oci", "--quiet"])

      assert File.exists?(Path.join(oci_dir, "modules/oci-instance/load_balancer.tf"))
      refute File.dir?(Path.join(aws_dir, "providers"))
      refute Enum.any?(file_tree(aws_dir), &(Path.basename(&1) === "load_balancer.tf"))
    end
  end

  describe "root variables.tf.eex (oci) — recognized keys" do
    test "T16: the <app>_project description lists load_balancer among recognized keys" do
      contents = root_variables_tf_eex_oci()

      assert contents =~ ~r/variable\s+"<%= @app_name %>_project"\s*\{\s*description\s*=\s*"[^"]*Recognized keys:[^"]*\bload_balancer\b[^"]*"/
    end
  end

  describe "render determinism" do
    test "T17: two pinned oci renders are byte-identical across the whole tree" do
      one = render_dir()
      on_exit(fn -> File.rm_rf!(one) end)
      two = render_dir()
      on_exit(fn -> File.rm_rf!(two) end)

      render(["--provider", "oci", "--render-dir", one, "--pem-app-name", "s2-determinism", "--quiet"])
      render(["--provider", "oci", "--render-dir", two, "--pem-app-name", "s2-determinism", "--quiet"])

      assert file_tree(one) === file_tree(two)

      for relative_path <- file_tree(one), File.regular?(Path.join(one, relative_path)) do
        assert File.read!(Path.join(one, relative_path)) ===
                 File.read!(Path.join(two, relative_path)),
               "#{relative_path} differed between runs"
      end
    end
  end
end
