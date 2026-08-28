defmodule Mix.Tasks.DeployEx.LoadTest.InitTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.DeployEx.LoadTest.Init

  describe "script_template/0 (false-green guard at the source)" do
    setup do
      %{template: Init.script_template()}
    end

    test "aborts the run on a high failure rate instead of reporting success", %{template: template} do
      assert template =~ "http_req_failed"
      assert template =~ "rate<0.01"
      assert template =~ "abortOnFail: true"
    end

    test "documents insecureSkipTLSVerify for self-signed/IP-target scripts", %{template: template} do
      assert template =~ "insecureSkipTLSVerify"
      assert template =~ ~r/self-signed|IP/
    end
  end
end
