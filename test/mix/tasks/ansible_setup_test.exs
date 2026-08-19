defmodule Mix.Tasks.Ansible.SetupTest do
  use ExUnit.Case, async: true

  alias DeployEx.QaNode
  alias Mix.Tasks.Ansible.Setup

  # parse_args/1 is private — mirror the OptionParser config here.
  # Same pattern as deploy_ex_qa_deploy_test.exs.

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, i: :instance_id, b: :git_branch],
      switches: [
        directory: :string,
        only: :keep,
        except: :keep,
        force: :boolean,
        quiet: :boolean,
        parallel: :integer,
        include_qa: :boolean,
        instance_id: :keep,
        git_branch: :string,
        aws_region: :string,
        no_tui: :boolean
      ]
    )
  end

  describe "parse_args/1 option parsing" do
    test "--git-branch parses to opts[:git_branch]" do
      {opts, _extra} = parse_args(["--git-branch", "qa/gamma_charts"])
      assert opts[:git_branch] === "qa/gamma_charts"
    end

    test "-b alias parses to opts[:git_branch]" do
      {opts, _extra} = parse_args(["-b", "qa/gamma_charts"])
      assert opts[:git_branch] === "qa/gamma_charts"
    end

    test "opts[:git_branch] is nil when --git-branch not passed" do
      {opts, _extra} = parse_args(["--include-qa"])
      assert is_nil(opts[:git_branch])
    end

    test "--git-branch and --instance-id can be combined" do
      {opts, _extra} =
        parse_args(["--git-branch", "qa/gamma_charts", "--instance-id", "i-0abc1234"])

      assert opts[:git_branch] === "qa/gamma_charts"
      assert Keyword.get_values(opts, :instance_id) === ["i-0abc1234"]
    end

    test "repeated --instance-id values collect via Keyword.get_values/2" do
      {opts, _extra} =
        parse_args(["--instance-id", "i-1", "--instance-id", "i-2"])

      assert Keyword.get_values(opts, :instance_id) === ["i-1", "i-2"]
    end

    test "--git-branch is a string switch — last value wins when repeated" do
      {opts, _extra} =
        parse_args(["--git-branch", "qa/one", "--git-branch", "qa/two"])

      assert opts[:git_branch] === "qa/two"
    end
  end

  describe "derive_branch/2" do
    test "returns nil when no nodes and no git-branch flag" do
      assert is_nil(Setup.derive_branch([], nil))
    end

    test "returns the git-branch flag when no nodes carry a branch tag" do
      assert "qa/foo" === Setup.derive_branch([%QaNode{git_branch: nil}], "qa/foo")
    end

    test "returns the single shared branch from node tags" do
      nodes = [
        %QaNode{git_branch: "qa/foo"},
        %QaNode{git_branch: "qa/foo"}
      ]

      assert "qa/foo" === Setup.derive_branch(nodes, nil)
    end

    test "accepts matching git-branch flag + node tag" do
      assert "qa/foo" === Setup.derive_branch([%QaNode{git_branch: "qa/foo"}], "qa/foo")
    end

    test "raises when nodes carry conflicting GitBranch tags" do
      nodes = [
        %QaNode{git_branch: "qa/foo"},
        %QaNode{git_branch: "qa/bar"}
      ]

      assert_raise Mix.Error, ~r/Conflicting GitBranch/, fn ->
        Setup.derive_branch(nodes, nil)
      end
    end

    test "raises when git-branch flag conflicts with node tag" do
      assert_raise Mix.Error, ~r/Conflicting GitBranch/, fn ->
        Setup.derive_branch([%QaNode{git_branch: "qa/bar"}], "qa/foo")
      end
    end

    test "treats empty-string branch tags as absent" do
      nodes = [%QaNode{git_branch: ""}, %QaNode{git_branch: "qa/foo"}]
      assert "qa/foo" === Setup.derive_branch(nodes, nil)
    end
  end
end
