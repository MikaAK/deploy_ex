defmodule DeployEx.MimirBlockLegibilityTest do
  use ExUnit.Case, async: true

  # MEASURED (see p2-mimir-core-port/briefs/mimir-block-legibility.md): three
  # independent agents in a consumer repo deleted the grafana_mimir_url metrics
  # block from their RENDERED alloy_config.alloy.j2 as dead code — one landed.
  # grafana_mimir_url is undefined in that repo, so the {% if %} never fires
  # there; a reader with only that repo in view sees a guard on an undefined
  # variable, directly below the closing `}` of loki.write, with nothing
  # explaining it.
  #
  # Upstream (this repo) the block is well protected — mimir_role_test.exs and
  # priv_renderer_mimir_test.exs both pin it, so deleting it here fails tests
  # immediately. Nothing protects the RENDERED copy a consumer actually edits,
  # and a per-consumer comment is the wrong fix (ansible.build's unguarded
  # File.cp_r! overwrites any local template edit on every regeneration, but a
  # consumer can still delete the block from the deployed artifact before the
  # next regen runs). The explanation has to live where it reaches the reader
  # who deletes it: the rendered artifact itself.
  #
  # ROLE-LEVEL SCOPE (MEASURED by the brief's author, not re-derived here): the
  # consumer's copy of grafana_alloy/tasks/main.yaml has drifted 47 lines
  # against deploy_ex's origin/main copy, while the template has drifted only
  # 29 — the task file is where local engineers spend edit/read attention, the
  # template is the file they touch least. A guard living only in the
  # low-drift template is invisible to anyone auditing the role primarily
  # through its (higher-drift, more-read) task list. So the explanation is
  # added in BOTH places: a `//` comment in the template (what ships to
  # production and what the three deleting agents were literally looking at),
  # and a `#` comment in tasks/main.yaml next to the task that renders it (what
  # a role-level auditor reads first).

  @priv_ansible_dir Path.expand("../../priv/ansible", __DIR__)
  @alloy_path Path.join(@priv_ansible_dir, "roles/grafana_alloy/templates/alloy_config.alloy.j2")
  @tasks_path Path.join(@priv_ansible_dir, "roles/grafana_alloy/tasks/main.yaml")

  # The immediate parent commit — grafana_mimir_url_configured predicate fix,
  # no legibility comment yet. Resolved by SHA, not a floating ref, so this
  # stays the correct "before" snapshot regardless of what HEAD becomes once
  # this change is committed.
  @before_commit_sha "a42527a272ca8a7510ed6c131e87ce8bbeb4c434"

  @comment_marker "grafana_mimir_url_configured, supplied by deploy_ex's own"

  @base_context %{
    "grafana_loki_url" => "http://loki.internal:3100",
    "app_name" => "my_app",
    "inventory_hostname" => "app-001",
    "instance_id" => "i-0abc123",
    "alloy_app_metrics_port" => 4050,
    "alloy_app_metrics_scrape_app_names" => []
  }

  # SECTION: the template — explanation present in source and survives rendering

  describe "alloy_config.alloy.j2 — legibility comment" do
    test "a // comment sits directly above the mimir gate, not a # (Alloy has no # comment)" do
      content = File.read!(@alloy_path)

      assert content =~ ~r{//[^\n]*#{Regex.escape(@comment_marker)}}
      refute content =~ ~r{#[^\n]*grafana_mimir_url_configured, supplied}
    end

    test "explains: intentional, deploy_ex-supplied, and restored by the next regeneration" do
      content = File.read!(@alloy_path)
      [comment_block] = Regex.run(~r{(// [^\n]*\n)+}, content, capture: :first)

      assert comment_block =~ "grafana_mimir_url_configured"
      assert comment_block =~ "group_vars"
      assert comment_block =~ ~r/not.*dead|dead.*not/i
      assert comment_block =~ ~r/mix ansible\.build/
    end

    test "the comment survives rendering into the output — undefined arm" do
      rendered = render_jinja_file!(@alloy_path, @base_context)

      assert rendered =~ @comment_marker
      assert_alloy_valid!(rendered)
    end

    test "the comment survives rendering into the output — configured (real value) arm" do
      context =
        @base_context
        |> Map.put("grafana_mimir_url", "http://10.0.1.40:8080")
        |> Map.put("grafana_mimir_url_configured", true)

      rendered = render_jinja_file!(@alloy_path, context)

      assert rendered =~ @comment_marker
      assert_alloy_valid!(rendered)
    end

    test "deletion-mutation arm: stripping the comment makes the survives-rendering assertion go red" do
      original = File.read!(@alloy_path)
      mutated = strip_legibility_comment(original)

      refute original === mutated, "mutation target not found — refusing a silent no-op"

      tmp_path = write_tmp_template!(mutated)
      rendered = render_jinja_file!(tmp_path, @base_context)
      File.rm!(tmp_path)

      # This is the exact assertion the "survives rendering" tests above make.
      # Run against a deliberately comment-stripped copy, it must fail — proving
      # those tests are not vacuous and would catch a well-meaning deletion.
      refute rendered =~ @comment_marker
      assert_alloy_valid!(rendered)
    end
  end

  # SECTION: the role's task file — same explanation, reachable without opening
  # the rendered template at all

  describe "grafana_alloy/tasks/main.yaml — role-level legibility comment" do
    test "a comment next to the templating task explains the mimir gate, referencing group_vars" do
      content = File.read!(@tasks_path)

      assert content =~ "grafana_mimir_url_configured"
      assert content =~ "group_vars"
      assert content =~ ~r/mix ansible\.build/
    end

    test "the comment sits immediately above the task that renders alloy_config.alloy.j2" do
      content = File.read!(@tasks_path)

      [comment_block, task_block] =
        Regex.split(~r/(?=- name: Add Alloy config to \/root\/alloy_config\.alloy)/, content, parts: 2)

      assert task_block =~ "Add Alloy config"

      comment_lines =
        comment_block
        |> String.split("\n")
        |> Enum.reverse()
        |> Enum.take_while(&(String.trim(&1) == "" or String.trim_leading(&1) |> String.starts_with?("#")))

      assert Enum.any?(comment_lines, &(&1 =~ "grafana_mimir_url_configured"))
    end

    test "tasks/main.yaml is still valid YAML after adding the comment" do
      content = File.read!(@tasks_path)

      assert {:ok, _parsed} = YamlElixir.read_from_string(content)
    end

    test "deletion-mutation arm: stripping the task-file comment makes the presence assertion go red" do
      original = File.read!(@tasks_path)
      mutated = strip_task_comment(original)

      refute original === mutated, "mutation target not found — refusing a silent no-op"

      refute mutated =~ "grafana_mimir_url_configured"
      assert {:ok, _parsed} = YamlElixir.read_from_string(mutated)
    end
  end

  # SECTION: render-diff — output identical to the pre-legibility commit apart
  # from the added comment lines, across every arm exercised by the predicate
  # and F59 work already landed on this branch.

  describe "render-diff — no behaviour change, only added text" do
    test "undefined arm: stripping // comment lines from the after-render reproduces the before-render exactly" do
      assert_render_diff_is_comment_only!(@base_context)
    end

    test "sentinel arm" do
      context = Map.put(@base_context, "grafana_mimir_url", "http://FILL_IN_AFTER_FIRST_APPLY:8080")
      assert_render_diff_is_comment_only!(context)
    end

    test "real value arm" do
      context =
        @base_context
        |> Map.put("grafana_mimir_url", "http://10.0.1.40:8080")
        |> Map.put("grafana_mimir_url_configured", true)

      assert_render_diff_is_comment_only!(context)
    end

    test "F59 scoped-out arm" do
      context =
        @base_context
        |> Map.put("grafana_mimir_url", "http://10.0.1.40:8080")
        |> Map.put("grafana_mimir_url_configured", true)
        |> Map.put("app_name", "server")
        |> Map.put("alloy_app_metrics_scrape_app_names", ["pipeline"])

      assert_render_diff_is_comment_only!(context)
    end
  end

  # SECTION: helpers

  defp assert_render_diff_is_comment_only!(context) do
    before_content = git_show!(@before_commit_sha, "priv/ansible/roles/grafana_alloy/templates/alloy_config.alloy.j2")

    before_rendered = render_jinja_source!(before_content, context)
    after_rendered = render_jinja_file!(@alloy_path, context)

    after_rendered_stripped =
      after_rendered
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) |> String.starts_with?("//")))
      |> Enum.join("\n")

    assert after_rendered_stripped === before_rendered
  end

  defp git_show!(sha, path) do
    {output, exit_status} = System.cmd("git", ["show", "#{sha}:#{path}"], cd: @priv_ansible_dir |> Path.join("../.."))

    if exit_status !== 0 do
      raise "git show #{sha}:#{path} failed (exit #{exit_status}): #{output}"
    end

    output
  end

  defp strip_legibility_comment(content) do
    Regex.replace(~r{(// [^\n]*\n)+}, content, "")
  end

  defp strip_task_comment(content) do
    Regex.replace(~r{(?:^\s*#[^\n]*\n)+(\s*- name: Add Alloy config to /root/alloy_config\.alloy)}m, content, "\\1")
  end

  defp write_tmp_template!(content) do
    tmp_path = Path.join(System.tmp_dir!(), "mimir_block_legibility_test_#{System.unique_integer([:positive])}.j2")
    File.write!(tmp_path, content)

    tmp_path
  end

  defp render_jinja_file!(template_path, context) do
    template_path |> File.read!() |> render_jinja_source!(context)
  end

  defp render_jinja_source!(source, context) do
    python = jinja_python!()
    script = jinja_render_script()
    context_json = Jason.encode!(context)
    source_path = write_tmp_template!(source)

    {output, exit_status} = System.cmd(python, ["-c", script, context_json, source_path])
    File.rm!(source_path)

    if exit_status !== 0 do
      raise "jinja2 render failed (exit #{exit_status}): #{output}"
    end

    output
  end

  defp jinja_python! do
    Enum.find(jinja_python_candidates(), &jinja_capable?/1) ||
      raise "no python interpreter with jinja2 installed was found among #{inspect(jinja_python_candidates())} — install ansible-core (brew install ansible) or jinja2 (pip install jinja2)"
  end

  defp jinja_python_candidates do
    [ansible_bundled_python(), System.find_executable("python3")]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ansible_bundled_python do
    with ansible_playbook when is_binary(ansible_playbook) <- System.find_executable("ansible-playbook"),
         {:ok, shebang_line} <- File.open(ansible_playbook, [:read], &IO.read(&1, :line)),
         "#!" <> python_path <- String.trim(shebang_line) do
      python_path
    else
      _ -> nil
    end
  end

  defp jinja_capable?(python) do
    case System.cmd(python, ["-c", "import jinja2"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  defp jinja_render_script do
    """
    import sys, json, jinja2
    context = json.loads(sys.argv[1])
    with open(sys.argv[2]) as source_file:
        source = source_file.read()
    template = jinja2.Template(source)
    sys.stdout.write(template.render(**context))
    """
  end

  defp assert_alloy_valid!(rendered_config) do
    exit_status = alloy_validate_exit_status(rendered_config)

    if exit_status !== 0 do
      raise "alloy validate rejected a render expected to be valid (exit #{exit_status}): #{rendered_config}"
    end

    :ok
  end

  defp alloy_validate_exit_status(rendered_config) do
    tmp_path = Path.join(System.tmp_dir!(), "mimir_block_legibility_test_alloy_#{System.unique_integer([:positive])}.alloy")
    File.write!(tmp_path, rendered_config)

    {_output, exit_status} = System.cmd(alloy_binary!(), ["validate", tmp_path], stderr_to_stdout: true)
    File.rm!(tmp_path)

    exit_status
  end

  defp alloy_binary! do
    System.find_executable("alloy") ||
      raise "the alloy CLI was not found on PATH — install it (https://github.com/grafana/alloy) to validate rendered configs for real"
  end
end
