defmodule DeployEx.TerraformVariablesTest do
  use ExUnit.Case, async: true

  alias DeployEx.TerraformVariables

  describe "terraform_clickhouse_variables/2" do
    test "renders nothing on oci unless --clickhouse is passed" do
      assert TerraformVariables.terraform_clickhouse_variables([], :oci) === ""
    end

    test "renders a DatabaseKey-tagged entry on oci when opted in" do
      rendered = TerraformVariables.terraform_clickhouse_variables([clickhouse: true], :oci)

      assert rendered =~ "_clickhouse = {"
      assert rendered =~ ~s(DatabaseKey = ")
      assert rendered =~ "_clickhouse\""
      assert rendered =~ ~s(shape       = "VM.Standard.E6.Flex")
    end

    test "renders nothing on aws even when opted in — aws users hand-write the entry" do
      assert TerraformVariables.terraform_clickhouse_variables([clickhouse: true], :aws) === ""
    end
  end

  describe "terraform_rabbitmq_variables/2" do
    test "renders nothing on oci unless --rabbitmq is passed" do
      assert TerraformVariables.terraform_rabbitmq_variables([], :oci) === ""
    end

    test "renders a DatabaseKey-tagged single node on oci when opted in" do
      rendered = TerraformVariables.terraform_rabbitmq_variables([rabbitmq: true], :oci)

      assert rendered =~ "_rabbitmq = {"
      assert rendered =~ "_rabbitmq\""
      refute rendered =~ "instance_count"
    end

    test "renders nothing on aws" do
      assert TerraformVariables.terraform_rabbitmq_variables([rabbitmq: true], :aws) === ""
    end
  end
end
