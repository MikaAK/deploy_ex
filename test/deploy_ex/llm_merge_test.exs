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

  describe "review_action/4" do
    test "identical action returns skip without LLM" do
      assert {:ok, %{decision: :skip, rationale: "No changes needed", path: "terraform/main.tf"}} ===
               LLMMerge.review_action({:identical, "terraform/main.tf"}, "/tmp/rendered", "/tmp/deploy")
    end

    test "user_only action returns skip without LLM" do
      assert {:ok, %{decision: :skip, rationale: "No changes needed", path: "terraform/custom.tf"}} ===
               LLMMerge.review_action({:user_only, "terraform/custom.tf"}, "/tmp/rendered", "/tmp/deploy")
    end

    test "new action returns apply without LLM" do
      assert {:ok, %{decision: :apply, rationale: "New file from upstream", path: "terraform/new.tf"}} ===
               LLMMerge.review_action({:new, "terraform/new.tf"}, "/tmp/rendered", "/tmp/deploy")
    end

    test "update action returns not_configured when no LLM provider" do
      assert {:error, :not_configured} ===
               LLMMerge.review_action(
                 {:update, "terraform/main.tf", "terraform/main.tf"},
                 "/tmp/rendered",
                 "/tmp/deploy",
                 llm_provider: nil
               )
    end

    test "removed action returns not_configured when no LLM provider" do
      assert {:error, :not_configured} ===
               LLMMerge.review_action(
                 {:removed, "terraform/old.tf"},
                 "/tmp/rendered",
                 "/tmp/deploy",
                 llm_provider: nil
               )
    end
  end
end
