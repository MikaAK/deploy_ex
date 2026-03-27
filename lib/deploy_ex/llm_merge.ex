defmodule DeployEx.LLMMerge do
  @moduledoc """
  Optional LLM-assisted merge for deploy_ex priv file upgrades.

  Works in two phases:

  1. **Plan**: receives a change manifest (new upstream files, modified files,
     user-only files) and asks the LLM to produce a merge plan — identifying
     renames, files to merge, and files to copy as-is. This handles cases where
     users have renamed or restructured files.

  2. **Execute**: for each merge action in the plan, reads file contents and
     asks the LLM to produce merged output.

  Direct same-path conflicts (upstream changed, user changed same file) skip
  the planning phase and go straight to per-file merge.

  Requires `langchain ~> 0.6` in your project's deps and an `:llm_provider`
  configured in your deploy_ex config:

      config :deploy_ex,
        llm_provider: {LangChain.ChatModels.ChatAnthropic, model: "claude-sonnet-4-6"}
  """

  @type change_manifest :: %{
          new_upstream: [String.t()],
          modified: [String.t()],
          user_only: [String.t()]
        }

  @type merge_action ::
          {:merge, upstream_path :: String.t(), user_path :: String.t()}
          | {:copy_upstream, String.t()}
          | {:keep_user, String.t()}

  # SECTION: Public API

  @spec merge_file(binary(), binary(), keyword()) :: {:ok, binary()} | {:error, atom() | term()}
  def merge_file(user_content, upstream_content, opts \\ []) do
    with {:ok, model} <- build_model(opts) do
      run_file_merge(model, user_content, upstream_content)
    end
  end

  @spec plan(change_manifest(), keyword()) :: {:ok, [merge_action()]} | {:error, atom() | term()}
  def plan(change_manifest, opts \\ []) do
    with {:ok, model} <- build_model(opts) do
      run_plan(model, change_manifest)
    end
  end

  @spec execute_merge(merge_action(), map(), keyword()) :: {:ok, binary()} | {:error, atom() | term()} | :skip
  def execute_merge(action, context, opts \\ [])

  def execute_merge({:merge, upstream_path, user_path}, %{deploy_folder: deploy_folder, priv_dir: priv_dir}, opts) do
    user_content = File.read!(Path.join(deploy_folder, user_path))
    upstream_content = File.read!(Path.join(priv_dir, upstream_path))

    with {:ok, model} <- build_model(opts) do
      run_file_merge(model, user_content, upstream_content)
    end
  end

  def execute_merge({:copy_upstream, _path}, _context, _opts), do: :skip
  def execute_merge({:keep_user, _path}, _context, _opts), do: :skip

  # SECTION: Model Setup

  defp build_model(opts) do
    case Keyword.get(opts, :llm_provider, DeployEx.Config.llm_provider()) do
      nil ->
        {:error, :not_configured}

      {model_module, model_opts} ->
        if not Code.ensure_loaded?(model_module) do
          {:error, :langchain_not_available}
        else
          {:ok, struct!(model_module, Map.new(model_opts))}
        end
    end
  end

  # SECTION: Planning

  defp run_plan(model, change_manifest) do
    prompt = """
    You are a deploy tool merge planner. An Elixir library ships Terraform and Ansible
    templates in its priv/ directory. A user exported those templates to ./deploys/ and
    may have renamed, restructured, or modified them.

    The library has been upgraded. Here is a summary of changes:

    NEW UPSTREAM FILES (not in user's manifest):
    #{format_file_list(change_manifest.new_upstream)}

    MODIFIED FILES (same path, user changed content):
    #{format_file_list(change_manifest.modified)}

    USER-ONLY FILES (in ./deploys/ but not in upstream priv/):
    #{format_file_list(change_manifest.user_only)}

    Analyze this and produce a merge plan as an Elixir list of tuples. Each tuple is one of:

    - {:merge, "upstream/path", "user/path"} — the user file is a renamed/modified version of
      the upstream file and their contents should be merged
    - {:copy_upstream, "upstream/path"} — this is genuinely new, copy it in
    - {:keep_user, "user/path"} — this is a user-created file unrelated to upstream, leave it alone

    For MODIFIED files (same path), emit {:merge, "path", "path"}.

    For NEW UPSTREAM files, check if any USER-ONLY file looks like a rename. If so, emit
    {:merge, "upstream/path", "user/path"}. Otherwise emit {:copy_upstream, "upstream/path"}.

    For USER-ONLY files not matched to an upstream rename, emit {:keep_user, "user/path"}.

    Return ONLY the Elixir list, no explanation. Example:
    [{:merge, "terraform/ec2.tf.eex", "terraform/my_ec2.tf.eex"}, {:copy_upstream, "terraform/new.tf"}]
    """

    case run_llm(model, prompt) do
      {:ok, response_text} -> parse_plan(response_text)
      {:error, _} = error -> error
    end
  end

  defp parse_plan(response_text) do
    response_text
    |> String.trim()
    |> Code.string_to_quoted()
    |> case do
      {:ok, actions} when is_list(actions) ->
        if Enum.all?(actions, &valid_action?/1), do: {:ok, actions}, else: {:error, :invalid_plan}

      _ ->
        {:error, :invalid_plan}
    end
  end

  defp valid_action?({:merge, upstream, user}) when is_binary(upstream) and is_binary(user), do: true
  defp valid_action?({:copy_upstream, path}) when is_binary(path), do: true
  defp valid_action?({:keep_user, path}) when is_binary(path), do: true
  defp valid_action?(_), do: false

  defp format_file_list([]), do: "(none)"

  defp format_file_list(files) do
    Enum.map_join(files, "\n", &"- #{&1}")
  end

  # SECTION: Per-File Merge

  defp run_file_merge(model, user_content, upstream_content) do
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

    case run_llm(model, prompt) do
      {:ok, merged} ->
        if String.contains?(merged, "<<<<<<<") do
          {:error, :conflict_markers_found}
        else
          {:ok, merged}
        end

      {:error, _} = error ->
        error
    end
  end

  # SECTION: LLM Call

  defp run_llm(model, prompt) do
    user_message = apply(LangChain.Message, :new_user!, [prompt])
    chain = apply(LangChain.Chains.LLMChain, :new!, [%{llm: model}])
    chain = apply(LangChain.Chains.LLMChain, :add_messages, [chain, [user_message]])

    case apply(LangChain.Chains.LLMChain, :run, [chain]) do
      {:ok, _chain, response} -> {:ok, response.content}
      {:error, _chain, error} -> {:error, error}
    end
  end
end
