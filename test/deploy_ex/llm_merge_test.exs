defmodule DeployEx.LLMMergeTest do
  use ExUnit.Case, async: true

  alias DeployEx.LLMMerge

  describe "merge/3 when llm_provider is not configured" do
    setup do
      original = Application.get_env(:deploy_ex, :llm_provider)
      Application.delete_env(:deploy_ex, :llm_provider)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:deploy_ex, :llm_provider)
        else
          Application.put_env(:deploy_ex, :llm_provider, original)
        end
      end)

      :ok
    end

    test "returns not_configured error" do
      assert {:error, :not_configured} = LLMMerge.merge(nil, "user content", "upstream content")
    end
  end

  describe "merge/3 when llm_provider module is not loaded" do
    setup do
      original = Application.get_env(:deploy_ex, :llm_provider)
      Application.put_env(:deploy_ex, :llm_provider, {NonExistentLLMModule, model: "some-model"})

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:deploy_ex, :llm_provider)
        else
          Application.put_env(:deploy_ex, :llm_provider, original)
        end
      end)

      :ok
    end

    test "returns langchain_not_available error" do
      assert {:error, :langchain_not_available} =
               LLMMerge.merge(nil, "user content", "upstream content")
    end
  end
end
