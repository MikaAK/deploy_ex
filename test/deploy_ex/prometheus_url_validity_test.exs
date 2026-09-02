defmodule DeployEx.PrometheusUrlValidityTest do
  use ExUnit.Case, async: true

  # `{% if grafana_prometheus_url is defined %}` tests PRESENCE. deploy_ex ships the
  # default as the sentinel "http://FILL_IN_AFTER_FIRST_APPLY:9090" — presence is
  # not validity. The placeholder satisfies `is defined`, so the Grafana datasource
  # renders unconditionally, pointing at a host that does not exist.
  #
  # This mirrors fix(grafana_mimir): gate Mimir wiring on URL validity, not
  # presence — same predicate shape, applied to the sibling variable
  # `grafana_prometheus_url`. This file does not hand-copy the Jinja2 expression:
  # `configured?/1` extracts the exact expression string from
  # group_vars/all.yaml.eex and re-renders it, so a change to the real
  # expression is what this test exercises — not a second, independently
  # written copy of the same logic in test code.

  @priv_ansible_dir Path.expand("../../priv/ansible", __DIR__)
  @datasources_path Path.join(@priv_ansible_dir, "roles/grafana_ui/templates/grafana-datasources.yaml.j2")
  @group_vars_path Path.join(@priv_ansible_dir, "group_vars/all.yaml.eex")

  @sentinel_url "http://FILL_IN_AFTER_FIRST_APPLY:9090"
  @real_url "http://10.0.1.41:9090"
  # Contains the substring "fill" but NOT the exact sentinel token
  # "FILL_IN_AFTER_FIRST_APPLY" — must be treated as a real URL, not the sentinel.
  @confusable_real_url "http://landfill-prometheus.internal:9090"

  @base_datasources_context %{
    "grafana_loki_url" => "http://loki.internal:3100"
  }

  # SECTION: the ONE definition — group_vars/all.yaml.eex

  describe "group_vars/all.yaml.eex — grafana_prometheus_url_configured (the one definition)" do
    test "declares grafana_prometheus_url_configured exactly once" do
      content = File.read!(@group_vars_path)

      assert length(Regex.scan(~r/grafana_prometheus_url_configured:/, content)) === 1
    end

    test "the expression treats presence as insufficient (mentions the sentinel token, not just `is defined`)" do
      content = File.read!(@group_vars_path)
      [_, expression] = Regex.run(~r/grafana_prometheus_url_configured: "\{\{ (.+) \}\}"/, content)

      assert expression =~ "FILL_IN_AFTER_FIRST_APPLY"
      assert expression =~ "is defined"
    end
  end

  # SECTION: the three-arm truth table, computed via the real (extracted) expression

  describe "configured?/1 — the real group_vars expression, all three arms" do
    test "undefined grafana_prometheus_url computes false" do
      refute configured?(%{})
    end

    test "the sentinel value computes false" do
      refute configured?(%{"grafana_prometheus_url" => @sentinel_url})
    end

    test "a real value computes true" do
      assert configured?(%{"grafana_prometheus_url" => @real_url})
    end

    test "a real value containing the confusable substring 'fill' still computes true" do
      assert configured?(%{"grafana_prometheus_url" => @confusable_real_url})
    end
  end

  # SECTION: grafana-datasources.yaml.j2 — real render + YAML parse, all three arms
  #
  # A substring assertion on this file would pass against broken/malformed YAML
  # that merely CONTAINS matching text — parse the render and assert on the
  # parsed structure instead.

  describe "grafana-datasources.yaml.j2 — grafana_prometheus_url_configured gate" do
    test "grafana_prometheus_url undefined: parses as valid YAML with no Prometheus datasource entry" do
      rendered =
        render_jinja_file!(
          @datasources_path,
          Map.put(@base_datasources_context, "grafana_prometheus_url_configured", configured?(%{}))
        )

      parsed = assert_valid_yaml!(rendered)
      prometheus_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Prometheus Metrics"))

      assert prometheus_entries === []
    end

    test "the sentinel value: parses as valid YAML with no Prometheus datasource entry (the new behaviour)" do
      context =
        @base_datasources_context
        |> Map.put("grafana_prometheus_url", @sentinel_url)
        |> Map.put("grafana_prometheus_url_configured", configured?(%{"grafana_prometheus_url" => @sentinel_url}))

      rendered = render_jinja_file!(@datasources_path, context)
      parsed = assert_valid_yaml!(rendered)
      prometheus_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Prometheus Metrics"))

      assert prometheus_entries === []
    end

    test "a real value: parses as valid YAML with exactly one correctly-shaped Prometheus datasource entry" do
      context =
        @base_datasources_context
        |> Map.put("grafana_prometheus_url", @real_url)
        |> Map.put("grafana_prometheus_url_configured", configured?(%{"grafana_prometheus_url" => @real_url}))

      rendered = render_jinja_file!(@datasources_path, context)
      parsed = assert_valid_yaml!(rendered)
      prometheus_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Prometheus Metrics"))

      assert [entry] = prometheus_entries
      assert entry["type"] === "prometheus"
      assert entry["url"] === @real_url
    end

    test "a real value containing 'fill': still parses with the Prometheus datasource entry present" do
      context =
        @base_datasources_context
        |> Map.put("grafana_prometheus_url", @confusable_real_url)
        |> Map.put(
          "grafana_prometheus_url_configured",
          configured?(%{"grafana_prometheus_url" => @confusable_real_url})
        )

      rendered = render_jinja_file!(@datasources_path, context)
      parsed = assert_valid_yaml!(rendered)
      prometheus_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Prometheus Metrics"))

      assert [entry] = prometheus_entries
      assert entry["url"] === @confusable_real_url
    end

    test "the Loki entry is always present regardless of the prometheus gate" do
      rendered =
        render_jinja_file!(
          @datasources_path,
          Map.put(@base_datasources_context, "grafana_prometheus_url_configured", false)
        )

      parsed = assert_valid_yaml!(rendered)
      loki_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Loki Logs"))

      assert [_entry] = loki_entries
    end

    test "the adjacent grafana_mimir_url_configured gate is UNTOUCHED (HARD BOUNDARY — PR #31's fix)" do
      content = File.read!(@datasources_path)

      assert content =~ "{% if grafana_mimir_url_configured %}"
    end
  end

  # SECTION: mutation arm — proving the gate can go wrong

  describe "mutation arm — grafana-datasources.yaml.j2" do
    test "reverting to a bare `is defined` presence check makes the sentinel case red" do
      original = File.read!(@datasources_path)

      mutated =
        String.replace(
          original,
          "{% if grafana_prometheus_url_configured %}",
          "{% if grafana_prometheus_url is defined %}"
        )

      refute original === mutated, "mutation target not found — refusing a silent no-op"

      tmp_path = write_tmp_template!(mutated)

      context = Map.put(@base_datasources_context, "grafana_prometheus_url", @sentinel_url)

      rendered = render_jinja_file!(tmp_path, context)
      File.rm!(tmp_path)

      parsed = assert_valid_yaml!(rendered)
      prometheus_entries = Enum.filter(parsed["datasources"], &(&1["name"] === "Prometheus Metrics"))

      # Under the reverted (presence-only) predicate, the sentinel — which IS
      # defined — renders the block. This is the exact regression the fix
      # exists to prevent; asserting it here proves the real file's test above
      # (which asserts the block is ABSENT for the sentinel) would go red
      # against this mutation.
      assert [_entry] = prometheus_entries
    end
  end

  # SECTION: helpers

  defp configured?(vars) do
    expression = prometheus_url_configured_expression()
    rendered = render_jinja_source!("{% if #{expression} %}true{% else %}false{% endif %}", vars)

    rendered === "true"
  end

  defp prometheus_url_configured_expression do
    content = File.read!(@group_vars_path)
    [_, expression] = Regex.run(~r/grafana_prometheus_url_configured: "\{\{ (.+) \}\}"/, content)

    expression
  end

  defp write_tmp_template!(content) do
    tmp_path = Path.join(System.tmp_dir!(), "prometheus_url_validity_test_#{System.unique_integer([:positive])}.j2")
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
end
