defmodule DeployEx.LLMMergeTest do
  use ExUnit.Case, async: true

  alias DeployEx.LLMMerge

  describe "merge_file/3 when llm_provider is not configured" do
    test "returns not_configured error" do
      assert {:error, :not_configured} =
               LLMMerge.merge_file("user content", "upstream content", llm_provider: nil)
    end
  end

  describe "plan/2 when llm_provider is not configured" do
    test "returns not_configured error" do
      change_manifest = %{new_upstream: ["a.tf"], modified: [], user_only: []}

      assert {:error, :not_configured} =
               LLMMerge.plan(change_manifest, llm_provider: nil)
    end
  end
end
