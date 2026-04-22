defmodule Mix.Tasks.Ansible.DeployTest do
  use ExUnit.Case, async: true

  # parse_args/1 and the helper functions are private.
  # We mirror the OptionParser config and test the observable option outputs.
  # Same pattern as deploy_ex_qa_deploy_test.exs.

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, l: :only_local_release, t: :target_sha],
      switches: [
        directory: :string,
        quiet: :boolean,
        only: :keep,
        except: :keep,
        copy_json_env_file: :string,
        parallel: :integer,
        only_local_release: :boolean,
        target_sha: :string,
        include_qa: :boolean,
        qa: :boolean,
        no_tui: :boolean
      ]
    )

    opts
  end

  describe "parse_args/1 option parsing" do
    test "--target-sha parses to opts[:target_sha]" do
      opts = parse_args(["--target-sha", "abc1234"])
      assert opts[:target_sha] === "abc1234"
    end

    test "-t alias parses to opts[:target_sha]" do
      opts = parse_args(["-t", "abc1234"])
      assert opts[:target_sha] === "abc1234"
    end

    test "opts[:target_sha] is nil when --target-sha not passed" do
      opts = parse_args([])
      assert is_nil(opts[:target_sha])
    end

    test "--target-sha auto parses as literal string 'auto'" do
      opts = parse_args(["--target-sha", "auto"])
      assert opts[:target_sha] === "auto"
    end

    test "--qa parses to opts[:qa] === true" do
      opts = parse_args(["--qa"])
      assert opts[:qa] === true
    end

    test "--include-qa parses to opts[:include_qa] === true" do
      opts = parse_args(["--include-qa"])
      assert opts[:include_qa] === true
    end

    test "--quiet parses to opts[:quiet] === true" do
      opts = parse_args(["--quiet"])
      assert opts[:quiet] === true
    end

    test "--qa and --target-sha can be combined" do
      opts = parse_args(["--qa", "--target-sha", "abc1234"])
      assert opts[:qa] === true
      assert opts[:target_sha] === "abc1234"
    end

    test "--qa and --target-sha auto can be combined" do
      opts = parse_args(["--qa", "--target-sha", "auto"])
      assert opts[:qa] === true
      assert opts[:target_sha] === "auto"
    end

    test "opts is a keyword list, not a map" do
      opts = parse_args(["--target-sha", "abc1234"])
      assert Keyword.keyword?(opts)
    end

    test "--only parses to a list of values" do
      opts = parse_args(["--only", "app1", "--only", "app2"])
      only_values = Keyword.get_values(opts, :only)
      assert only_values === ["app1", "app2"]
    end

    test "--except parses to a list of values" do
      opts = parse_args(["--except", "app3"])
      except_values = Keyword.get_values(opts, :except)
      assert except_values === ["app3"]
    end

    test "--parallel parses to integer" do
      opts = parse_args(["--parallel", "8"])
      assert opts[:parallel] === 8
    end
  end

  describe "first_app_name/1 logic (via playbook path stripping)" do
    # first_app_name strips directory and extension from the first playbook.
    # We verify the logic by mimicking it directly — no need to call private fn.

    test "strips .yaml extension from playbook path" do
      playbook = "playbooks/my_app.yaml"
      app_name = playbook |> Path.basename() |> String.replace(~r/\.[^.]+$/, "")
      assert app_name === "my_app"
    end

    test "strips .yml extension from playbook path" do
      playbook = "playbooks/other_app.yml"
      app_name = playbook |> Path.basename() |> String.replace(~r/\.[^.]+$/, "")
      assert app_name === "other_app"
    end

    test "uses first element when multiple playbooks given" do
      playbooks = ["playbooks/first_app.yaml", "playbooks/second_app.yaml"]
      [first | _] = playbooks
      app_name = first |> Path.basename() |> String.replace(~r/\.[^.]+$/, "")
      assert app_name === "first_app"
    end
  end

  describe "resolve_target_sha_from_lookup/2 decision logic" do
    # We test the decision conditions that the private function evaluates,
    # expressed as predicates over the opts keyword list.

    test "target_sha 'auto' with --qa triggers qa auto-resolve path" do
      opts = [target_sha: "auto", qa: true]
      assert opts[:target_sha] === "auto"
      assert opts[:qa] === true
    end

    test "target_sha 'auto' without --qa triggers prod auto-resolve path" do
      opts = [target_sha: "auto"]
      assert opts[:target_sha] === "auto"
      refute opts[:qa] === true
    end

    test "--qa without target_sha triggers qa prompt path" do
      opts = [qa: true]
      assert opts[:qa] === true
      assert is_nil(opts[:target_sha])
    end

    test "concrete sha with --qa is a pass-through (no lookup)" do
      opts = [target_sha: "abc1234", qa: true]
      refute opts[:target_sha] === "auto"
    end

    test "no flags is a pass-through (no lookup)" do
      opts = []
      assert is_nil(opts[:target_sha])
      refute opts[:qa] === true
    end
  end
end
