defmodule DeployEx.AwsInstanceModuleTest do
  use ExUnit.Case, async: true

  # priv/terraform/modules/aws-instance/main.tf is HCL, not Elixir-rendered —
  # covered here via structural assertions on the raw file text (same exemption/
  # pattern as test/deploy_ex/mimir_role_test.exs's raw j2 content assertions).
  # No terraform/tofu binary dependency in this test — see the D5 dispatch for
  # why (no network/credentials available to `tofu init` in CI).
  #
  # MEASURED (D5 backlog, AZ-SUBNET-MATCH): when `instance_availability_zone` is
  # pinned, `data.aws_subnets.az_specific` (main.tf:27-39) filters subnet_ids to
  # that AZ and `local.selected_subnet_id` (main.tf:76-80) takes the first match.
  # When that filtered list is empty it silently falls back to a subnet in ANY
  # AZ (random_shuffle.subnet_id.result[0]), while the instance's
  # `availability_zone` (main.tf:152) still uses the pinned AZ — the plan
  # renders clean; AWS rejects the mismatch at apply with an opaque error.
  #
  # This suite pins: a lifecycle precondition exists on aws_instance.ec2_instance
  # guarding the AZ-pinned path, its condition references the AZ-filtered subnet
  # data source (not just subnet_ids generally), and its error_message names BOTH
  # the pinned AZ and the subnet list that was searched — a message missing
  # either half fails this contract per the dispatch ("the message is part of
  # the contract, not decoration").

  @main_tf_path Path.expand("../../priv/terraform/modules/aws-instance/main.tf", __DIR__)

  defp read_main_tf, do: File.read!(@main_tf_path)

  # Isolates the aws_instance.ec2_instance resource body so assertions can't
  # accidentally match content belonging to a different resource/data source
  # elsewhere in the file (e.g. the plain `data.aws_subnets.az_specific` usage
  # already present in `local.selected_subnet_id`, well before this resource).
  defp ec2_instance_resource_body(content) do
    {instance_start, _length} = :binary.match(content, ~s(resource "aws_instance" "ec2_instance"))
    {next_resource_start, _length} = :binary.match(content, ~s(resource "aws_ebs_volume" "ec2_ebs"))

    binary_part(content, instance_start, next_resource_start - instance_start)
  end

  defp extract_error_message(resource_body) do
    Regex.run(~r/error_message\s*=\s*"([^\n]*)"/, resource_body, capture: :all_but_first)
  end

  # SECTION: precondition exists and guards the AZ-pinned path

  describe "aws-instance module — AZ/subnet mismatch precondition" do
    test "aws_instance.ec2_instance has a lifecycle precondition block" do
      instance_body = read_main_tf() |> ec2_instance_resource_body()

      assert instance_body =~ ~r/lifecycle\s*\{/
      assert instance_body =~ "precondition {"
    end

    test "the precondition's condition references the AZ-filtered subnet data source" do
      instance_body = read_main_tf() |> ec2_instance_resource_body()

      assert instance_body =~ "data.aws_subnets.az_specific[0].ids"
    end

    test "the error message names both the pinned AZ and the subnet list that was searched" do
      instance_body = read_main_tf() |> ec2_instance_resource_body()

      assert [message] = extract_error_message(instance_body)
      assert message =~ "var.instance_availability_zone"
      assert message =~ "var.subnet_ids"
    end
  end
end
