defmodule Mix.Tasks.DeployEx.LoadTestTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.DeployEx.LoadTest

  describe "exec command help (stale prometheus default + missing --pem, LT-FIX-A)" do
    setup do
      %{output: capture_io(fn -> LoadTest.run(["--command", "exec"]) end)}
    end

    test "does not advertise the dead hardcoded prometheus default", %{output: output} do
      refute output =~ "10.0.1.40"
    end

    test "describes prometheus URL discovery by tag", %{output: output} do
      assert output =~ "discovered by tag"
    end

    test "mentions the no-prometheus-found warning path", %{output: output} do
      assert output =~ ~r/no metrics export|without metrics/
    end

    test "documents the --pem flag", %{output: output} do
      assert output =~ "--pem"
    end
  end
end
