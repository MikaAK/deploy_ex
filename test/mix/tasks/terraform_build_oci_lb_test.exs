defmodule Mix.Tasks.Terraform.BuildOciLbTest do
  # async: false — matches ansible_build_render_test.exs; this file grows render-driven rows
  # in later sprints (S2/S3) alongside these template-content rows
  use ExUnit.Case, async: false

  @load_balancer_tf "terraform/providers/oci/modules/oci-instance/load_balancer.tf"
  @module_outputs_tf "terraform/providers/oci/modules/oci-instance/outputs.tf"
  @module_main_tf "terraform/providers/oci/modules/oci-instance/main.tf"
  @module_variables_tf "terraform/providers/oci/modules/oci-instance/variables.tf"
  @root_variables_tf_eex "terraform/variables.tf.eex"
  @aws_instance_main_tf "terraform/modules/aws-instance/main.tf"

  defp load_balancer_tf, do: @load_balancer_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp module_outputs_tf, do: @module_outputs_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp module_main_tf, do: @module_main_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp module_variables_tf, do: @module_variables_tf |> DeployExHelpers.priv_folder() |> File.read!()

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
end
