defmodule DeployEx.MimirUrlValidityTest do
  use ExUnit.Case, async: true

  # `{% if grafana_mimir_url is defined %}` tests PRESENCE. deploy_ex ships the
  # default as the sentinel "http://FILL_IN_AFTER_FIRST_APPLY:8080" — presence is
  # not validity. Both consuming templates (grafana_alloy's Alloy pipeline and
  # grafana_ui's Grafana datasource) must treat the sentinel as absent, or Alloy
  # correctly refuses to write to Mimir while Grafana still points at it (or the
  # reverse) — the two halves would disagree about whether Mimir exists.
  #
  # ONE DEFINITION: the sentinel-validity check lives in exactly one place —
  # `priv/ansible/group_vars/all.yaml.eex`'s `grafana_mimir_url_configured`
  # computed group_var — because group_vars/all is the only mechanism in this
  # codebase that is visible to every role/template without per-role copies (role
  # defaults are role-scoped; grafana_alloy's defaults are not visible to
  # grafana_ui's template, and vice versa, unless both roles happen to run in the
  # same play, which they do not). Both templates read the ONE computed boolean
  # bare — `{% if grafana_mimir_url_configured %}` — no `| default(...)` filter.
  #
  # This test file does not hand-copy that Jinja2 expression: `configured?/1`
  # extracts the exact expression string from group_vars/all.yaml.eex and
  # re-renders it, so a change to the real expression is what this test exercises
  # — not a second, independently-written copy of the same logic in test code.

  @priv_ansible_dir Path.expand("../../priv/ansible", __DIR__)
  @alloy_path Path.join(@priv_ansible_dir, "roles/grafana_alloy/templates/alloy_config.alloy.j2")
  @datasources_path Path.join(@priv_ansible_dir, "roles/grafana_ui/templates/grafana-datasources.yaml.j2")
  @group_vars_path Path.join(@priv_ansible_dir, "group_vars/all.yaml.eex")

  @sentinel_url "http://FILL_IN_AFTER_FIRST_APPLY:8080"
  @real_url "http://10.0.1.40:8080"
  # Contains the substring "fill" but NOT the exact sentinel token
  # "FILL_IN_AFTER_FIRST_APPLY" — must be treated as a real URL, not the sentinel.
  @confusable_real_url "http://landfill-mimir.internal:8080"

  @base_alloy_context %{
    "grafana_loki_url" => "http://loki.internal:3100",
    "app_name" => "my_app",
    "inventory_hostname" => "app-001",
    "instance_id" => "i-0abc123",
    "alloy_app_metrics_port" => 4050
  }

  @base_datasources_context %{
    "grafana_loki_url" => "http://loki.internal:3100"
  }

  # SECTION: the ONE definition — group_vars/all.yaml.eex

  describe "group_vars/all.yaml.eex — grafana_mimir_url_configured (the one definition)" do
    test "declares grafana_mimir_url_configured exactly once" do
      content = File.read!(@group_vars_path)

      assert length(Regex.scan(~r/grafana_mimir_url_configured:/, content)) === 1
    end

    test "the expression treats presence as insufficient (mentions the sentinel token, not just `is defined`)" do
      content = File.read!(@group_vars_path)
      [_, expression] = Regex.run(~r/grafana_mimir_url_configured: "\{\{ (.+) \}\}"/, content)

      assert expression =~ "FILL_IN_AFTER_FIRST_APPLY"
      assert expression =~ "is defined"
    end
  end

  # SECTION: the three-arm truth table, computed via the real (extracted) expression

  describe "configured?/1 — the real group_vars expression, all three arms" do
    test "undefined grafana_mimir_url computes false" do
      refute configured?(%{})
    end

    test "the sentinel value computes false" do
      refute configured?(%{"grafana_mimir_url" => @sentinel_url})
    end

    test "a real value computes true" do
      assert configured?(%{"grafana_mimir_url" => @real_url})
    end

    test "a real value containing the confusable substring 'fill' still computes true" do
      assert configured?(%{"grafana_mimir_url" => @confusable_real_url})
    end
  end

  # SECTION: alloy_config.alloy.j2 — real render + alloy validate, all three arms

  describe "alloy_config.alloy.j2 — grafana_mimir_url_configured gate" do
    test "grafana_mimir_url undefined: no prometheus.scrape/remote_write block, valid Alloy" do
      rendered = render_jinja_file!(@alloy_path, Map.put(@base_alloy_context, "grafana_mimir_url_configured", configured?(%{})))

      refute rendered =~ "prometheus.scrape"
      refute rendered =~ "prometheus.remote_write"
      assert_alloy_valid!(rendered)
    end

    test "the sentinel value: no prometheus.scrape/remote_write block, valid Alloy (the new behaviour)" do
      context =
        @base_alloy_context
        |> Map.put("grafana_mimir_url", @sentinel_url)
        |> Map.put("grafana_mimir_url_configured", configured?(%{"grafana_mimir_url" => @sentinel_url}))

      rendered = render_jinja_file!(@alloy_path, context)

      refute rendered =~ "prometheus.scrape"
      refute rendered =~ "prometheus.remote_write"
      assert_alloy_valid!(rendered)
    end

    test "a real value: the block is present and valid Alloy" do
      context =
        @base_alloy_context
        |> Map.put("grafana_mimir_url", @real_url)
        |> Map.put("grafana_mimir_url_configured", configured?(%{"grafana_mimir_url" => @real_url}))

      rendered = render_jinja_file!(@alloy_path, context)

      assert rendered =~ "prometheus.scrape \"node_exporter\""
      assert rendered =~ "prometheus.scrape \"app\""
      assert rendered =~ ~s(url = "#{@real_url}/api/v1/push")
      assert_alloy_valid!(rendered)
    end

    test "a real value containing 'fill': the block still renders (not mistaken for the sentinel), valid Alloy" do
      context =
        @base_alloy_context
        |> Map.put("grafana_mimir_url", @confusable_real_url)
        |> Map.put("grafana_mimir_url_configured", configured?(%{"grafana_mimir_url" => @confusable_real_url}))

      rendered = render_jinja_file!(@alloy_path, context)

      assert rendered =~ "prometheus.scrape \"node_exporter\""
      assert_alloy_valid!(rendered)
    end

    test "node_exporter's :9100 target is present in every arm, unaffected by the validity gate" do
      for context <- [
            Map.put(@base_alloy_context, "grafana_mimir_url_configured", false),
            @base_alloy_context
            |> Map.put("grafana_mimir_url", @real_url)
            |> Map.put("grafana_mimir_url_configured", true)
          ] do
        rendered = render_jinja_file!(@alloy_path, context)

        if context["grafana_mimir_url_configured"] do
          assert rendered =~ "\"__address__\" = \"localhost:9100\","
        else
          refute rendered =~ "9100"
        end
      end
    end

    test "the app_name is defined gate is untouched — still a bare presence test, not folded into the mimir validity check" do
      content = File.read!(@alloy_path)

      assert content =~ "{% if app_name is defined %}"
    end
  end

  # SECTION: grafana-datasources.yaml.j2 — real render + YAML parse, all three arms
  #
  # A substring assertion on this file has the same vacuity problem the `#`-comment
  # had on the Alloy file: `content =~ "Mimir Metrics"` would still pass against
  # broken/malformed YAML that merely CONTAINS that text. Parse the render and
  # assert on the parsed structure instead.

  describe "grafana-datasources.yaml.j2 — grafana_mimir_url_configured gate" do
    test "grafana_mimir_url undefined: parses as valid YAML with no Mimir datasource entry" do
      rendered =
        render_jinja_file!(@datasources_path, Map.put(@base_datasources_context, "grafana_mimir_url_configured", configured?(%{})))

      parsed = assert_valid_yaml!(rendered)
      mimir_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Mimir Metrics"))

      assert mimir_entries === []
    end

    test "the sentinel value: parses as valid YAML with no Mimir datasource entry (the new behaviour)" do
      context =
        @base_datasources_context
        |> Map.put("grafana_mimir_url", @sentinel_url)
        |> Map.put("grafana_mimir_url_configured", configured?(%{"grafana_mimir_url" => @sentinel_url}))

      rendered = render_jinja_file!(@datasources_path, context)
      parsed = assert_valid_yaml!(rendered)
      mimir_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Mimir Metrics"))

      assert mimir_entries === []
    end

    test "a real value: parses as valid YAML with exactly one correctly-shaped Mimir datasource entry" do
      context =
        @base_datasources_context
        |> Map.put("grafana_mimir_url", @real_url)
        |> Map.put("grafana_mimir_url_configured", configured?(%{"grafana_mimir_url" => @real_url}))

      rendered = render_jinja_file!(@datasources_path, context)
      parsed = assert_valid_yaml!(rendered)
      mimir_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Mimir Metrics"))

      assert [entry] = mimir_entries
      assert entry["type"] === "prometheus"
      assert entry["url"] === "#{@real_url}/prometheus"
    end

    test "a real value containing 'fill': still parses with the Mimir datasource entry present" do
      context =
        @base_datasources_context
        |> Map.put("grafana_mimir_url", @confusable_real_url)
        |> Map.put("grafana_mimir_url_configured", configured?(%{"grafana_mimir_url" => @confusable_real_url}))

      rendered = render_jinja_file!(@datasources_path, context)
      parsed = assert_valid_yaml!(rendered)
      mimir_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Mimir Metrics"))

      assert [entry] = mimir_entries
      assert entry["url"] === "#{@confusable_real_url}/prometheus"
    end

    test "the Loki entry is always present regardless of the mimir gate" do
      rendered =
        render_jinja_file!(@datasources_path, Map.put(@base_datasources_context, "grafana_mimir_url_configured", false))

      parsed = assert_valid_yaml!(rendered)
      loki_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Loki Logs"))

      assert [_entry] = loki_entries
    end

    test "the adjacent grafana_prometheus_url gate is UNTOUCHED — still a bare presence test (HARD BOUNDARY)" do
      content = File.read!(@datasources_path)

      assert content =~ "{% if grafana_prometheus_url is defined %}"
    end
  end

  # SECTION: mutation arms — one per template, each proving the gate can go wrong

  describe "mutation arm — alloy_config.alloy.j2" do
    test "reverting to a bare `is defined` presence check makes the sentinel case red" do
      original = File.read!(@alloy_path)
      mutated = String.replace(original, "{% if grafana_mimir_url_configured %}", "{% if grafana_mimir_url is defined %}")

      refute original === mutated, "mutation target not found — refusing a silent no-op"

      tmp_path = write_tmp_template!(mutated)

      context =
        @base_alloy_context
        |> Map.put("grafana_mimir_url", @sentinel_url)

      rendered = render_jinja_file!(tmp_path, context)
      File.rm!(tmp_path)

      # Under the reverted (presence-only) predicate, the sentinel — which IS
      # defined — renders the block. This is the exact regression the fix exists
      # to prevent; asserting it here proves the real file's test above (which
      # asserts the block is ABSENT for the sentinel) would go red against this
      # mutation.
      assert rendered =~ "prometheus.scrape"
    end
  end

  describe "mutation arm — grafana-datasources.yaml.j2" do
    test "reverting to a bare `is defined` presence check makes the sentinel case red" do
      original = File.read!(@datasources_path)
      mutated = String.replace(original, "{% if grafana_mimir_url_configured %}", "{% if grafana_mimir_url is defined %}")

      refute original === mutated, "mutation target not found — refusing a silent no-op"

      tmp_path = write_tmp_template!(mutated)

      context =
        @base_datasources_context
        |> Map.put("grafana_mimir_url", @sentinel_url)

      rendered = render_jinja_file!(tmp_path, context)
      File.rm!(tmp_path)

      parsed = assert_valid_yaml!(rendered)
      mimir_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Mimir Metrics"))

      assert [_entry] = mimir_entries
    end
  end

  # SECTION: helpers

  defp configured?(vars) do
    expression = mimir_url_configured_expression()
    rendered = render_jinja_source!("{% if #{expression} %}true{% else %}false{% endif %}", vars)

    rendered === "true"
  end

  defp mimir_url_configured_expression do
    content = File.read!(@group_vars_path)
    [_, expression] = Regex.run(~r/grafana_mimir_url_configured: "\{\{ (.+) \}\}"/, content)

    expression
  end

  defp write_tmp_template!(content) do
    tmp_path = Path.join(System.tmp_dir!(), "mimir_url_validity_test_#{System.unique_integer([:positive])}.j2")
    File.write!(tmp_path, content)

    tmp_path
  end

  defp assert_valid_yaml!(rendered) do
    YamlElixir.read_from_string!(rendered)
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

  # SECTION: alloy validate — same design as mimir_role_test.exs on the port branch:
  # raises loudly (never skips) when the alloy CLI is absent.

  defp assert_alloy_valid!(rendered_config) do
    exit_status = alloy_validate_exit_status(rendered_config)

    if exit_status !== 0 do
      raise "alloy validate rejected a render expected to be valid (exit #{exit_status}): #{rendered_config}"
    end

    :ok
  end

  defp alloy_validate_exit_status(rendered_config) do
    tmp_path = Path.join(System.tmp_dir!(), "mimir_url_validity_test_alloy_#{System.unique_integer([:positive])}.alloy")
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
