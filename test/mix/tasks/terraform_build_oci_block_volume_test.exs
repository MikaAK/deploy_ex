defmodule Mix.Tasks.Terraform.BuildOciBlockVolumeTest do
  # async: false — matches terraform_build_oci_lb_test.exs, this file also drives real
  # renders through Mix.Tasks.Terraform.Build.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Terraform.Build

  @module_main_tf "terraform/providers/oci/modules/oci-instance/main.tf"
  @module_variables_tf "terraform/providers/oci/modules/oci-instance/variables.tf"
  @cloud_init_tftpl "terraform/providers/oci/modules/oci-instance/cloud_init_data.yaml.tftpl"
  @root_instance_tf_eex "terraform/providers/oci/instance.tf.eex"
  @root_variables_tf_eex_oci "terraform/providers/oci/variables.tf.eex"
  @aws_instance_main_tf "terraform/modules/aws-instance/main.tf"

  defp module_main_tf, do: @module_main_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp module_variables_tf, do: @module_variables_tf |> DeployExHelpers.priv_folder() |> File.read!()
  defp cloud_init_tftpl, do: @cloud_init_tftpl |> DeployExHelpers.priv_folder() |> File.read!()
  defp root_instance_tf_eex, do: @root_instance_tf_eex |> DeployExHelpers.priv_folder() |> File.read!()
  defp root_variables_tf_eex_oci, do: @root_variables_tf_eex_oci |> DeployExHelpers.priv_folder() |> File.read!()
  defp aws_instance_main_tf, do: @aws_instance_main_tf |> DeployExHelpers.priv_folder() |> File.read!()

  defp render(args), do: capture_io(fn -> Build.run(args) end)

  defp render_dir do
    Path.join(System.tmp_dir!(), "p2_tf_bv_#{System.unique_integer([:positive])}")
  end

  # SECTION: module variables.tf — opt-in, default-off block volume knobs

  describe "module variables.tf — block volume variables" do
    test "declares enable_block_volume defaulting to false, not nullable" do
      contents = module_variables_tf()

      assert contents =~ ~r/variable\s+"enable_block_volume"\s*\{[\s\S]*?default\s*=\s*false[\s\S]*?nullable\s*=\s*false/
    end

    test "declares block_volume_size_gbs defaulting to 50 (OCI's block-volume minimum)" do
      contents = module_variables_tf()

      assert contents =~ ~r/variable\s+"block_volume_size_gbs"\s*\{[\s\S]*?default\s*=\s*50[\s\S]*?nullable\s*=\s*false/
    end
  end

  # SECTION: module main.tf — the volume, the attachment, and cloud-init wiring

  describe "module main.tf — oci_core_volume" do
    test "gates count on enable_block_volume * instance_count (opt-in, off by default)" do
      contents = module_main_tf()

      assert contents =~ ~r/resource\s+"oci_core_volume"\s+"data"\s*\{\s*count\s*=\s*var\.enable_block_volume\s*\?\s*var\.instance_count\s*:\s*0/
      assert contents =~ ~r/size_in_gbs\s*=\s*var\.block_volume_size_gbs/
    end

    test "tags carry Group, Environment, and ManagedBy" do
      contents = module_main_tf()

      [volume_block] = Regex.run(~r/resource\s+"oci_core_volume"\s+"data"\s*\{.*?\n\}/s, contents)

      assert volume_block =~ ~s(Group         = var.resource_group)
      assert volume_block =~ ~s(Environment   = var.environment)
      assert volume_block =~ ~s(ManagedBy     = "DeployEx")
    end
  end

  describe "module main.tf — oci_core_volume_attachment" do
    test "uses paravirtualized attachment, not iscsi" do
      contents = module_main_tf()

      assert contents =~ ~r/resource\s+"oci_core_volume_attachment"\s+"data"\s*\{[\s\S]*?attachment_type\s*=\s*"paravirtualized"/
      refute contents =~ ~r/attachment_type\s*=\s*"iscsi"/
    end

    test "gates count on enable_block_volume * instance_count, same as the volume" do
      contents = module_main_tf()

      assert contents =~ ~r/resource\s+"oci_core_volume_attachment"\s+"data"\s*\{\s*count\s*=\s*var\.enable_block_volume\s*\?\s*var\.instance_count\s*:\s*0/
    end

    test "wires instance_id and volume_id from the paired resources, not a bare [0] index" do
      contents = module_main_tf()

      assert contents =~ ~r/instance_id\s*=\s*oci_core_instance\.main\[count\.index\]\.id/
      assert contents =~ ~r/volume_id\s*=\s*oci_core_volume\.data\[count\.index\]\.id/
    end

    test "pins device to the documented paravirtualized convention, not an AWS-shaped nvme-by-id path" do
      contents = module_main_tf()

      assert contents =~ ~r{device\s*=\s*"/dev/oracleoci/oraclevdb"}
      refute contents =~ ~r{/dev/disk/by-id/nvme}
    end
  end

  describe "module main.tf — instance metadata carries cloud-init user_data only when block volume is enabled" do
    test "merges a user_data key onto metadata, gated on enable_block_volume" do
      contents = module_main_tf()

      assert contents =~ ~r/metadata\s*=\s*merge\(/
      assert contents =~ ~r/var\.enable_block_volume\s*\?\s*\{\s*user_data\s*=/
    end

    test "ssh_authorized_keys is-empty-omits logic is preserved" do
      contents = module_main_tf()

      assert contents =~ ~r/var\.ssh_public_key\s*==\s*""\s*\?\s*\{\}\s*:\s*\{\s*ssh_authorized_keys\s*=\s*var\.ssh_public_key\s*\}/
    end
  end

  # SECTION: cloud-init asset — properties, not AWS's text

  describe "cloud_init_data.yaml.tftpl — properties mirrored from the AWS script" do
    test "installs xfsprogs" do
      assert cloud_init_tftpl() =~ "xfsprogs"
    end

    test "preserves an existing filesystem rather than reformatting" do
      contents = cloud_init_tftpl()

      assert contents =~ ~r/blkid\s+-s\s+TYPE/
      assert contents =~ ~r/mkfs\.xfs/
      # The mkfs call must be reachable only from the "no filesystem found" branch,
      # never unconditionally — this is what makes formatting idempotent-safe.
      # $$ (not $) is deliberate: this is a Terraform templatefile() source, where a
      # literal shell "$" must be escaped as "$$" to survive Terraform's own ${...}
      # interpolation pass, same convention as AWS's prepare-ebs-volume.sh.
      assert contents =~ ~r/if\s+\[\s+-n\s+"\$\$\{FSTYPE\}"\s+\]/
    end

    test "writes an fstab entry with nofail and a device timeout" do
      contents = cloud_init_tftpl()

      assert contents =~ "nofail"
      assert contents =~ "x-systemd.device-timeout=30s"
      assert contents =~ "/etc/fstab"
    end

    test "is safe to re-run — mount is gated on mountpoint -q, not unconditional" do
      contents = cloud_init_tftpl()

      assert contents =~ ~r/mountpoint\s+-q/
    end

    test "attempts an xfs_growfs on every run (matches AWS's unconditional-growth call site)" do
      assert cloud_init_tftpl() =~ ~r/xfs_growfs/
    end

    test "runcmd invokes the prepare script" do
      contents = cloud_init_tftpl()

      assert contents =~ "runcmd:"
      assert contents =~ ~r/runcmd:\s*\n\s*-\s*\/usr\/local\/sbin\/prepare-block-volume\.sh/
    end
  end

  # SECTION: root wiring — instance.tf.eex and variables.tf.eex

  describe "root instance.tf.eex — wires block_volume via try(), matching the load_balancer pattern" do
    test "wires enable_block_volume and block_volume_size_gbs" do
      contents = root_instance_tf_eex()

      assert contents =~ ~r/enable_block_volume\s*=\s*try\(each\.value\.block_volume\.enable,\s*false\)/
      assert contents =~ ~r/block_volume_size_gbs\s*=\s*try\(each\.value\.block_volume\.size_gbs,\s*null\)/
    end
  end

  describe "root variables.tf.eex (oci) — recognized keys" do
    test "the <app>_project description lists block_volume among recognized keys" do
      contents = root_variables_tf_eex_oci()

      assert contents =~ ~r/variable\s+"<%= @app_name %>_project"\s*\{\s*description\s*=\s*"[^"]*Recognized keys:[^"]*\bblock_volume\b[^"]*"/
    end
  end

  # SECTION: AWS byte-parity — D1 must not perturb the AWS path at all

  describe "AWS byte-parity regression guard" do
    test "aws-instance/main.tf has no oci_ resources and no block-volume additions" do
      contents = aws_instance_main_tf()

      refute contents =~ ~r/oci_/
      refute contents =~ "enable_block_volume"
      refute contents =~ "paravirtualized"
    end
  end

  # SECTION: render invariant — toggling mimir on an oci render changes ONLY root
  # variables.tf's mimir_db block, nothing else in the whole tree (D1's own
  # infrastructure — the module's volume/attachment resources and the two
  # instance.tf wiring lines — is present identically whether or not any app
  # requests it, since it is generic opt-in support, not mimir-specific).

  defp file_tree(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  describe "render invariant — oci mimir on vs off" do
    test "the whole-tree diff is confined to variables.tf, and its diff is exactly the mimir_db block" do
      off_dir = render_dir()
      on_exit(fn -> File.rm_rf!(off_dir) end)
      render(["--provider", "oci", "--render-dir", off_dir, "--pem-app-name", "p2-bv-invariant", "--no-mimir", "--quiet"])

      on_dir = render_dir()
      on_exit(fn -> File.rm_rf!(on_dir) end)
      render(["--provider", "oci", "--render-dir", on_dir, "--pem-app-name", "p2-bv-invariant", "--quiet"])

      assert file_tree(off_dir) === file_tree(on_dir)

      changed_files =
        for relative_path <- file_tree(off_dir),
            File.regular?(Path.join(off_dir, relative_path)),
            File.read!(Path.join(off_dir, relative_path)) !== File.read!(Path.join(on_dir, relative_path)) do
          relative_path
        end

      assert changed_files === ["variables.tf"]

      off_variables_tf = File.read!(Path.join(off_dir, "variables.tf"))
      on_variables_tf = File.read!(Path.join(on_dir, "variables.tf"))

      refute off_variables_tf =~ "mimir_db"
      assert on_variables_tf =~ "mimir_db = {"
      assert on_variables_tf =~ ~r/block_volume\s*=\s*\{\s*enable\s*=\s*true/
    end
  end

  # SECTION: full render — the cloud-init asset actually ships, and the AWS render is untouched

  describe "render — cloud-init asset ships in an oci render, never in an aws render" do
    test "oci render carries cloud_init_data.yaml.tftpl.eex output flattened alongside the module" do
      dir = render_dir()
      on_exit(fn -> File.rm_rf!(dir) end)
      render(["--provider", "oci", "--render-dir", dir, "--pem-app-name", "p2-bv-render", "--quiet"])

      assert File.exists?(Path.join(dir, "modules/oci-instance/cloud_init_data.yaml.tftpl"))
    end

    test "aws render never gains a providers/ dir or an oci-instance module" do
      dir = render_dir()
      on_exit(fn -> File.rm_rf!(dir) end)
      render(["--render-dir", dir, "--pem-app-name", "p2-bv-render-aws", "--quiet"])

      refute File.dir?(Path.join(dir, "providers"))
      refute File.dir?(Path.join(dir, "modules/oci-instance"))
    end
  end
end
