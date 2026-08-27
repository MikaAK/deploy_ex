defmodule DeployEx.K6RunnerAdversarialTest do
  @moduledoc """
  Adversarial contract probe for `DeployEx.K6Runner` — written against
  docs/superpowers/plans/lt-fix/spec.md (D1, D2) and sprint-2-provision.md
  ONLY. This file was NOT written by reading k6_runner.ex; every assertion
  pins a promise made in the contract, not a detail of the implementation.
  """

  use ExUnit.Case, async: true

  alias DeployEx.K6Runner

  # Binaries assumed present on the debian-13 base AMI (stock POSIX/coreutils/
  # bash-builtins/apt tooling) or installed by earlier lines in the script.
  # This list is a mechanical derivation aid, not an authoritative debian
  # package manifest — any binary flagged as a violation should be checked
  # by hand before treating it as confirmed.
  @stock_binaries [
    "sh",
    "bash",
    "echo",
    "printf",
    "mkdir",
    "chmod",
    "chown",
    "chgrp",
    "touch",
    "cat",
    "tee",
    "mv",
    "cp",
    "rm",
    "rmdir",
    "ln",
    "test",
    "[",
    "true",
    "false",
    "export",
    "set",
    "unset",
    "cd",
    "pwd",
    "sleep",
    "date",
    "hostname",
    "hostnamectl",
    "systemctl",
    "service",
    "useradd",
    "usermod",
    "groupadd",
    "groups",
    "newgrp",
    "id",
    "grep",
    "awk",
    "sed",
    "cut",
    "head",
    "tail",
    "tr",
    "wc",
    "xargs",
    "find",
    "curl",
    "wget",
    "gpg",
    "gpg2",
    "apt-get",
    "apt",
    "apt-key",
    "dpkg",
    "dpkg-query",
    "gunzip",
    "tar",
    "gzip",
    "unzip",
    "su",
    "sudo",
    "env",
    "source",
    "exec",
    "ps",
    "kill",
    "timeout",
    "nohup",
    "which",
    "command",
    "type",
    "ip",
    "ifconfig",
    "readlink",
    "basename",
    "dirname",
    "install",
    "getent",
    "systemd-run",
    "lsb_release",
    "uname",
    "df",
    "du",
    "mount",
    "chpasswd",
    "passwd",
    "wait",
    "shift",
    "return",
    "trap",
    "read",
    "local",
    "declare",
    "readonly",
    "eval",
    "openssl",
    "python3",
    "perl",
    "wall",
    "jq"
  ]

  # apt/apt-get package names whose provided binary name differs from the
  # package name itself.
  @package_to_binary %{
    "awscli" => "aws",
    "gnupg" => "gpg",
    "gnupg2" => "gpg",
    "ca-certificates" => nil,
    "apt-transport-https" => nil,
    "software-properties-common" => nil
  }

  @control_keywords [
    "if",
    "then",
    "else",
    "elif",
    "fi",
    "for",
    "while",
    "until",
    "do",
    "done",
    "case",
    "esac",
    "function",
    "select",
    "{",
    "}",
    "in"
  ]

  describe "build_user_data/0 — D1 debian-native user_data" do
    test "returns a binary" do
      assert is_binary(K6Runner.build_user_data())
    end

    test "never invokes the Amazon-Linux-only ec2-metadata binary" do
      refute K6Runner.build_user_data() =~ "ec2-metadata"
    end

    test "keeps set -euo pipefail so setup aborts loudly on first failure" do
      assert K6Runner.build_user_data() =~ "set -euo pipefail"
    end

    test "installs the k6 binary via apt/dpkg somewhere in the script" do
      script = K6Runner.build_user_data()
      assert script =~ ~r/k6/i

      install_line =
        script
        |> lines_with_index()
        |> Enum.find(fn {line, _index} ->
          (line =~ "apt-get install" or line =~ "apt install" or line =~ "dpkg -i") and
            line =~ "k6"
        end)

      refute is_nil(install_line), "no line installs the k6 binary via apt/apt-get/dpkg"
    end

    test "every invoked binary is stock debian/POSIX or installed earlier in the script" do
      script = K6Runner.build_user_data()
      installed = installed_binaries_by_line(script)

      violations =
        script
        |> invoked_commands_by_line()
        |> Enum.reject(fn {command, _index} -> command in @stock_binaries end)
        |> Enum.reject(fn {command, index} ->
          case Map.fetch(installed, command) do
            {:ok, install_index} -> install_index <= index
            :error -> false
          end
        end)
        |> Enum.uniq()

      assert violations === [],
             "binaries invoked without being stock-debian or installed earlier in the " <>
               "script (mechanically derived, verify by hand): #{inspect(violations)}"
    end

    test "grants admin ownership/permissions over /srv/k6 before any other use of the path" do
      script = K6Runner.build_user_data()
      srv_lines = srv_k6_lines(script)

      assert srv_lines !== [], "script never references /srv/k6 at all"

      ownership_index =
        srv_lines
        |> Enum.find(fn {line, _index} ->
          (line =~ "chown" or line =~ "chmod") and line =~ "admin"
        end)
        |> case do
          {_line, index} -> index
          nil -> flunk("no line grants admin ownership/permissions over /srv/k6")
        end

      other_use_index =
        srv_lines
        |> Enum.reject(fn {line, _index} ->
          (line =~ "chown" or line =~ "chmod") and line =~ "admin"
        end)
        |> Enum.reject(fn {line, _index} -> line =~ "mkdir" end)
        |> case do
          [{_line, index} | _rest] -> index
          [] -> nil
        end

      if not is_nil(other_use_index) do
        assert ownership_index <= other_use_index,
               "line #{other_use_index} uses /srv/k6 before ownership is granted at line " <>
                 "#{ownership_index}"
      end
    end
  end

  describe "from_json/1 hostile inputs (round-trip safety)" do
    test "unknown keys are ignored without raising" do
      assert %K6Runner{} = K6Runner.from_json(%{"totally_unknown_key" => "value"})
    end

    test "missing keys resolve to nil fields" do
      runner = K6Runner.from_json(%{})

      runner
      |> Map.from_struct()
      |> Enum.each(fn {field, value} ->
        assert is_nil(value),
               "expected field #{inspect(field)} to be nil for an empty payload, " <>
                 "got #{inspect(value)}"
      end)
    end

    test "round-trips through to_json/1 back to an identical struct" do
      original =
        K6Runner.from_json(%{
          "instance_id" => "i-0123456789abcdef0",
          "public_ip" => "10.0.101.171",
          "state" => "running"
        })

      encoded = K6Runner.to_json(original)

      decoded =
        case encoded do
          binary when is_binary(binary) -> Jason.decode!(binary)
          map when is_map(map) -> map
        end

      restored = K6Runner.from_json(decoded)

      assert restored === original
    end
  end

  defp lines_with_index(script) do
    script |> String.split("\n") |> Enum.with_index()
  end

  defp srv_k6_lines(script) do
    Enum.filter(lines_with_index(script), fn {line, _index} -> line =~ "/srv/k6" end)
  end

  defp invoked_commands_by_line(script) do
    script
    |> lines_with_index()
    |> Enum.flat_map(fn {line, index} ->
      line
      |> strip_comment()
      |> split_statements()
      |> Enum.map(&extract_command_word/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&{&1, index})
    end)
  end

  defp strip_comment(line) do
    case String.split(line, "#", parts: 2) do
      [code, _comment] -> code
      [code] -> code
    end
  end

  defp split_statements(line) do
    line
    |> String.split(~r/&&|\|\||;|\|/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 === ""))
  end

  defp extract_command_word(segment) do
    trimmed = segment |> strip_leading_assignments() |> String.trim()

    case trimmed do
      "" ->
        nil

      _not_empty ->
        word = trimmed |> String.split(~r/\s+/, trim: true) |> List.first()
        normalize_command_word(word)
    end
  end

  defp normalize_command_word(nil), do: nil
  defp normalize_command_word(word) when word in @control_keywords, do: nil

  defp normalize_command_word(word) do
    cond do
      String.starts_with?(word, "$") -> nil
      String.starts_with?(word, "(") -> nil
      String.starts_with?(word, "<") -> nil
      String.starts_with?(word, ">") -> nil
      true -> word |> String.trim_trailing(":") |> Path.basename()
    end
  end

  defp strip_leading_assignments(segment) do
    case Regex.run(~r/^\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+(.*)$/, segment) do
      [_match, rest] -> strip_leading_assignments(rest)
      nil -> segment
    end
  end

  defp installed_binaries_by_line(script) do
    script
    |> lines_with_index()
    |> Enum.reduce(%{}, fn {line, index}, accumulator ->
      line
      |> extract_install_targets()
      |> Enum.reduce(accumulator, fn binary, inner_accumulator ->
        Map.update(inner_accumulator, binary, index, &min(&1, index))
      end)
    end)
  end

  defp extract_install_targets(line) do
    cond do
      Regex.match?(~r/\b(apt-get|apt)\s+install\b/, line) ->
        line
        |> String.replace(~r/^.*\b(apt-get|apt)\s+install\b/, "")
        |> String.split(~r/\s+/, trim: true)
        |> Enum.reject(&String.starts_with?(&1, "-"))
        |> Enum.map(&resolve_package_binary/1)
        |> Enum.reject(&is_nil/1)

      Regex.match?(~r{(mv|cp|install|ln -s)\s+\S+\s+/(usr/local|usr)/bin/\S+}, line) ->
        case Regex.run(~r{/(?:usr/local|usr)/bin/(\S+)\s*$}, line) do
          [_match, binary] -> [binary]
          _no_match -> []
        end

      true ->
        []
    end
  end

  defp resolve_package_binary(package) do
    case Map.fetch(@package_to_binary, package) do
      {:ok, nil} -> nil
      {:ok, binary} -> binary
      :error -> package
    end
  end
end
