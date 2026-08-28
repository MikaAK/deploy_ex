defmodule Mix.Tasks.DeployEx.LoadTest.ListTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.DeployEx.LoadTest.List

  defp sample_runner do
    %DeployEx.K6Runner{
      instance_id: "i-0abc123",
      instance_name: "K6-Runner-test-1",
      state: "running",
      public_ip: "1.2.3.4",
      ipv6_address: nil,
      private_ip: "10.0.0.5",
      created_at: "2024-01-01T00:00:00Z"
    }
  end

  describe "output_runners/2 with --json" do
    test "emits valid JSON when opts is the keyword list OptionParser returns" do
      output = capture_io(fn ->
        List.output_runners([sample_runner()], json: true)
      end)

      assert {:ok, [%{"instance_id" => "i-0abc123"}]} = Jason.decode(output)
    end
  end

  describe "output_runners/2 without --json" do
    test "renders the table view by default" do
      output = capture_io(fn ->
        List.output_runners([sample_runner()], [])
      end)

      refute output =~ ~s("instance_id")
      assert output =~ "k6 Runners:"
    end
  end

  describe "render_result/2 with zero runners" do
    test "emits valid (empty array) JSON on stdout when --json is set" do
      output = capture_io(fn ->
        List.render_result({:ok, []}, json: true)
      end)

      assert {:ok, []} = Jason.decode(output)
    end

    test "prints the human 'no runners' message when --json is not set" do
      output = capture_io(fn ->
        List.render_result({:ok, []}, [])
      end)

      assert output =~ "No k6 runners found"
      refute output =~ "["
    end
  end
end
