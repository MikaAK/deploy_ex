defmodule DeployEx.AnsibleXmlTemplatesTest do
  use ExUnit.Case, async: true

  # An XML config fragment that does not parse is not a config problem — it is a service that
  # never starts. MEASURED: a `--` sequence inside an XML comment (XML 1.0 forbids it anywhere
  # in a comment body) made ClickHouse's Poco parser refuse
  # `users.d/zz-allow-default-network.xml` outright, so the daemon died before signalling
  # readiness and systemd reported "Failed with result 'protocol'" — indistinguishable at the
  # systemd layer from a Type=notify incompatibility, and it cost a long misdiagnosis.
  #
  # Ansible renders these with Jinja2, which nothing here can execute, so the Jinja constructs
  # are substituted out and the surrounding XML is parsed. That is enough to catch malformed
  # markup, unbalanced tags, and illegal comments — the failures that stop a daemon booting.
  @templates Path.wildcard("priv/ansible/**/*.xml.j2")

  test "there are XML templates to check, so this test cannot pass vacuously" do
    refute Enum.empty?(@templates)
  end

  for template <- @templates do
    test "#{template} renders parseable XML" do
      xml = unquote(template) |> File.read!() |> strip_jinja()

      assert {:ok, _parsed} = parse_xml(xml),
             "#{unquote(template)} does not parse as XML once Jinja constructs are removed. " <>
               "A config.d/users.d fragment that fails to parse stops the service booting."
    end
  end

  defp strip_jinja(contents) do
    contents
    |> String.replace(~r/\{\#.*?\#\}/s, "")
    |> String.replace(~r/\{%.*?%\}/s, "")
    |> String.replace(~r/\{\{.*?\}\}/s, "placeholder")
  end

  # xmerl is fed the UTF-8 BYTES, not Unicode codepoints. String.to_charlist/1 would hand it
  # codepoints, and it rejects anything above its assumed single-byte range — an em-dash in a
  # comment would fail as `bad_character, 8212` even though it is perfectly legal XML.
  defp parse_xml(xml) do
    {parsed, _rest} = :xmerl_scan.string(:binary.bin_to_list(xml), quiet: true)

    {:ok, parsed}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
