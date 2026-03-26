defmodule DeployEx.LLMMerge do
  @moduledoc """
  Optional LLM-assisted merge for deploy_ex priv file upgrades.

  Performs a 2-way merge: the LLM receives the user's modified version and
  the new upstream version, then produces a merged result that preserves
  user customizations while incorporating upstream changes. The `base`
  parameter is accepted for future 3-way merge support but is currently
  unused (only the content hash is stored in the manifest, not the full
  base content).

  Requires `langchain ~> 0.6` in your project's deps and an `:llm_provider`
  configured in your deploy_ex config:

      config :deploy_ex,
        llm_provider: {LangChain.ChatModels.ChatAnthropic, model: "claude-sonnet-4-6"}
        # or: {LangChain.ChatModels.ChatOpenAI, model: "gpt-4o"}
        # or: {LangChain.ChatModels.ChatOllamaAI, model: "llama3"}
  """

  @spec merge(binary() | nil, binary(), binary()) ::
          {:ok, binary()} | {:error, atom() | term()}
  def merge(_base, user_content, upstream_content) do
    case Application.get_env(:deploy_ex, :llm_provider) do
      nil ->
        {:error, :not_configured}

      {model_module, model_opts} ->
        do_merge(model_module, model_opts, user_content, upstream_content)
    end
  end

  defp do_merge(model_module, model_opts, user_content, upstream_content) do
    if not Code.ensure_loaded?(model_module) do
      {:error, :langchain_not_available}
    else
      run_llm_merge(model_module, model_opts, user_content, upstream_content)
    end
  end

  defp run_llm_merge(model_module, model_opts, user_content, upstream_content) do
    prompt = """
    You are a code merge assistant. I have two versions of a configuration or template file.

    USER VERSION (locally modified):
    ```
    #{user_content}
    ```

    UPSTREAM VERSION (from library upgrade):
    ```
    #{upstream_content}
    ```

    Produce a merged version that:
    1. Preserves all user customizations
    2. Incorporates all upstream changes (new variables, blocks, fixes)
    3. Resolves any conflicts by preferring user intent while keeping upstream structure

    Return ONLY the merged file content with no explanation, no markdown fencing.
    """

    chain_mod = LangChain.Chains.LLMChain
    message_mod = LangChain.Message

    model = struct!(model_module, Map.new(model_opts))
    user_message = Kernel.apply(message_mod, :new_user!, [prompt])
    chain = Kernel.apply(chain_mod, :new!, [%{llm: model}])
    chain = Kernel.apply(chain_mod, :add_messages, [chain, [user_message]])

    case Kernel.apply(chain_mod, :run, [chain]) do
      {:ok, _chain, response} ->
        merged = response.content

        if String.contains?(merged, "<<<<<<<") do
          {:error, :conflict_markers_found}
        else
          {:ok, merged}
        end

      {:error, _chain, error} ->
        {:error, error}
    end
  end
end
