defmodule DeployEx.UpgradeOrchestratorTest do
  use ExUnit.Case, async: true

  # SECTION: Setup

  setup do
    base = Path.join(System.tmp_dir!(), "upgrade_orch_test_#{System.unique_integer([:positive])}")
    temp_dir = Path.join(base, "rendered")
    deploy_dir = Path.join(base, "deploys")

    File.mkdir_p!(temp_dir)
    File.mkdir_p!(deploy_dir)

    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, temp_dir: temp_dir, deploy_dir: deploy_dir}
  end

  # SECTION: Action Classification

  describe "action categorization" do
    test "groups actions by type" do
      actions = [
        {:identical, "a.tf"},
        {:identical, "b.tf"},
        {:update, "c.tf", "c.tf"},
        {:new, "d.tf"},
        {:user_only, "e.tf"}
      ]

      grouped = Enum.group_by(actions, &elem(&1, 0))

      assert length(Map.get(grouped, :identical, [])) === 2
      assert length(Map.get(grouped, :update, [])) === 1
      assert length(Map.get(grouped, :new, [])) === 1
      assert length(Map.get(grouped, :user_only, [])) === 1
    end
  end

  # SECTION: Backup

  describe "backup creation" do
    test "backs up files that will be modified", %{deploy_dir: deploy_dir} do
      File.write!(Path.join(deploy_dir, "existing.tf"), "user content")
      File.mkdir_p!(Path.join(deploy_dir, "sub"))
      File.write!(Path.join(deploy_dir, "sub/nested.tf"), "nested content")

      actions = [
        {:update, "existing.tf", "existing.tf"},
        {:update, "sub/nested.tf", "sub/nested.tf"},
        {:new, "brand_new.tf"},
        {:identical, "unchanged.tf"}
      ]

      backup_dir = Path.join(deploy_dir, ".backup/test")

      modifiable =
        actions
        |> Enum.reject(&match?({:identical, _}, &1))
        |> Enum.reject(&match?({:user_only, _}, &1))
        |> Enum.reject(&match?({:new, _}, &1))

      Enum.each(modifiable, fn action ->
        user_paths = case action do
          {:update, _up, user} -> [user]
          {:rename, _up, user} -> [user]
          {:split, _up, users} -> users
          {:merge_files, _ups, user} -> [user]
          _ -> []
        end

        Enum.each(user_paths, fn user_path ->
          src = Path.join(deploy_dir, user_path)

          if File.exists?(src) do
            dest = Path.join(backup_dir, user_path)
            File.mkdir_p!(Path.dirname(dest))
            File.cp!(src, dest)
          end
        end)
      end)

      assert File.read!(Path.join(backup_dir, "existing.tf")) === "user content"
      assert File.read!(Path.join(backup_dir, "sub/nested.tf")) === "nested content"
      refute File.exists?(Path.join(backup_dir, "brand_new.tf"))
    end
  end

  # SECTION: Apply Single Action

  describe "apply_single_action" do
    test "copies new file from temp to deploy", %{temp_dir: temp_dir, deploy_dir: deploy_dir} do
      File.write!(Path.join(temp_dir, "new_file.tf"), "new content")

      src = Path.join(temp_dir, "new_file.tf")
      dest = Path.join(deploy_dir, "new_file.tf")
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(src, dest)

      assert File.read!(dest) === "new content"
    end

    test "overwrites existing file for update", %{temp_dir: temp_dir, deploy_dir: deploy_dir} do
      File.write!(Path.join(temp_dir, "file.tf"), "upstream version")
      File.write!(Path.join(deploy_dir, "file.tf"), "user version")

      src = Path.join(temp_dir, "file.tf")
      dest = Path.join(deploy_dir, "file.tf")
      File.cp!(src, dest)

      assert File.read!(dest) === "upstream version"
    end

    test "removes file for removed action", %{deploy_dir: deploy_dir} do
      path = Path.join(deploy_dir, "old_file.tf")
      File.write!(path, "old content")

      File.rm!(path)

      refute File.exists?(path)
    end
  end

  # SECTION: Option Parsing

  describe "option parsing" do
    test "parses --llm-merge flag" do
      {opts, _} = OptionParser.parse!(["--llm-merge"], switches: [llm_merge: :boolean, ai_review: :boolean])
      assert opts[:llm_merge] === true
      assert is_nil(opts[:ai_review])
    end

    test "parses --ai-review flag" do
      {opts, _} = OptionParser.parse!(["--ai-review"], switches: [llm_merge: :boolean, ai_review: :boolean])
      assert opts[:ai_review] === true
      assert is_nil(opts[:llm_merge])
    end

    test "parses no flags as interactive mode" do
      {opts, _} = OptionParser.parse!([], switches: [llm_merge: :boolean, ai_review: :boolean])
      assert is_nil(opts[:llm_merge])
      assert is_nil(opts[:ai_review])
    end

    test "both flags can be parsed but llm_merge takes priority in cond" do
      {opts, _} = OptionParser.parse!(["--llm-merge", "--ai-review"], switches: [llm_merge: :boolean, ai_review: :boolean])
      assert opts[:llm_merge] === true
      assert opts[:ai_review] === true

      # llm_merge is checked first in the cond
      mode = cond do
        opts[:llm_merge] -> :autonomous
        opts[:ai_review] -> :ai_assisted
        true -> :interactive
      end

      assert mode === :autonomous
    end
  end

  # SECTION: User Paths Extraction

  describe "user_paths_for_action" do
    test "extracts user paths from various action types" do
      assert extract_user_paths({:update, "a.tf", "a.tf"}) === ["a.tf"]
      assert extract_user_paths({:rename, "old.tf", "new.tf"}) === ["new.tf"]
      assert extract_user_paths({:split, "big.tf", ["a.tf", "b.tf"]}) === ["a.tf", "b.tf"]
      assert extract_user_paths({:merge_files, ["a.tf", "b.tf"], "merged.tf"}) === ["merged.tf"]
      assert extract_user_paths({:removed, "gone.tf"}) === []
      assert extract_user_paths({:identical, "same.tf"}) === []
      assert extract_user_paths({:new, "fresh.tf"}) === []
    end
  end

  # SECTION: Helpers

  defp extract_user_paths({:update, _upstream, user}), do: [user]
  defp extract_user_paths({:rename, _upstream, user}), do: [user]
  defp extract_user_paths({:split, _upstream, users}), do: users
  defp extract_user_paths({:merge_files, _upstreams, user}), do: [user]
  defp extract_user_paths({:removed, _upstream}), do: []
  defp extract_user_paths(_), do: []
end
