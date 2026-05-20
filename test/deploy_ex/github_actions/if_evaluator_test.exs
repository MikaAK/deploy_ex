defmodule DeployEx.GitHubActions.IfEvaluatorTest do
  use ExUnit.Case, async: true

  alias DeployEx.GitHubActions.IfEvaluator

  @qa_ctx %{
    "github.ref" => "refs/heads/qa/cfx_web-canary",
    "github.ref_name" => "qa/cfx_web-canary",
    "github.event_name" => "push",
    "github.head_ref" => "",
    "github.base_ref" => ""
  }

  @main_ctx %{
    "github.ref" => "refs/heads/main",
    "github.ref_name" => "main",
    "github.event_name" => "push",
    "github.head_ref" => "",
    "github.base_ref" => ""
  }

  describe "evaluate/2 — literals & operators" do
    test "true is true" do
      assert {:ok, true} === IfEvaluator.evaluate("true", %{})
    end

    test "false is false" do
      assert {:ok, false} === IfEvaluator.evaluate("false", %{})
    end

    test "string equality" do
      assert {:ok, true} === IfEvaluator.evaluate("'push' == 'push'", %{})
      assert {:ok, false} === IfEvaluator.evaluate("'push' == 'pull_request'", %{})
    end

    test "string inequality" do
      assert {:ok, false} === IfEvaluator.evaluate("'push' != 'push'", %{})
      assert {:ok, true} === IfEvaluator.evaluate("'push' != 'pull_request'", %{})
    end

    test "logical AND short-circuits" do
      assert {:ok, true} === IfEvaluator.evaluate("true && true", %{})
      assert {:ok, false} === IfEvaluator.evaluate("true && false", %{})
      assert {:ok, false} === IfEvaluator.evaluate("false && true", %{})
    end

    test "logical OR short-circuits" do
      assert {:ok, true} === IfEvaluator.evaluate("true || false", %{})
      assert {:ok, true} === IfEvaluator.evaluate("false || true", %{})
      assert {:ok, false} === IfEvaluator.evaluate("false || false", %{})
    end

    test "negation" do
      assert {:ok, false} === IfEvaluator.evaluate("!true", %{})
      assert {:ok, true} === IfEvaluator.evaluate("!false", %{})
    end

    test "parens override precedence" do
      assert {:ok, true} ===
               IfEvaluator.evaluate("(false || true) && true", %{})
    end
  end

  describe "evaluate/2 — `${{ }}` wrapper" do
    test "strips ${{ }} wrapper before evaluating" do
      assert {:ok, true} === IfEvaluator.evaluate("${{ true }}", %{})
    end

    test "handles ${{ }} with embedded operators" do
      assert {:ok, true} === IfEvaluator.evaluate("${{ 'a' == 'a' }}", %{})
    end
  end

  describe "evaluate/2 — functions" do
    test "startsWith/2" do
      assert {:ok, true} === IfEvaluator.evaluate("startsWith('foobar', 'foo')", %{})
      assert {:ok, false} === IfEvaluator.evaluate("startsWith('foobar', 'bar')", %{})
    end

    test "endsWith/2" do
      assert {:ok, true} === IfEvaluator.evaluate("endsWith('foobar', 'bar')", %{})
      assert {:ok, false} === IfEvaluator.evaluate("endsWith('foobar', 'foo')", %{})
    end

    test "contains/2" do
      assert {:ok, true} === IfEvaluator.evaluate("contains('hello world', 'lo wo')", %{})
      assert {:ok, false} === IfEvaluator.evaluate("contains('hello', 'xyz')", %{})
    end

    test "success/0 defaults to true" do
      assert {:ok, true} === IfEvaluator.evaluate("success()", %{})
    end

    test "failure/0 defaults to false" do
      assert {:ok, false} === IfEvaluator.evaluate("failure()", %{})
    end

    test "cancelled/0 defaults to false" do
      assert {:ok, false} === IfEvaluator.evaluate("cancelled()", %{})
    end

    test "always/0 is true" do
      assert {:ok, true} === IfEvaluator.evaluate("always()", %{})
    end
  end

  describe "evaluate/2 — context lookups" do
    test "github.ref" do
      assert {:ok, true} ===
               IfEvaluator.evaluate("github.ref == 'refs/heads/main'", @main_ctx)
    end

    test "missing context key returns :unknown" do
      assert :unknown === IfEvaluator.evaluate("inputs.foo == 'bar'", @qa_ctx)
    end

    test "unknown function returns :unknown" do
      assert :unknown === IfEvaluator.evaluate("toJson(github.ref)", @qa_ctx)
    end
  end

  describe "evaluate/2 — real deploy gates" do
    @deploy_main_if "${{ !failure() && !cancelled() && ((github.event_name == 'push' && github.ref == 'refs/heads/main') || github.event_name == 'workflow_dispatch') }}"
    @deploy_qa_if "${{ !failure() && !cancelled() && github.event_name == 'push' && (startsWith(github.ref, 'refs/heads/qa-') || startsWith(github.ref, 'refs/heads/qa/')) }}"

    test "deploy-main gate fires on main branch" do
      assert {:ok, true} === IfEvaluator.evaluate(@deploy_main_if, @main_ctx)
    end

    test "deploy-main gate does NOT fire on qa branch" do
      assert {:ok, false} === IfEvaluator.evaluate(@deploy_main_if, @qa_ctx)
    end

    test "deploy-qa gate fires on qa/ branch" do
      assert {:ok, true} === IfEvaluator.evaluate(@deploy_qa_if, @qa_ctx)
    end

    test "deploy-qa gate fires on qa- branch" do
      ctx = %{@qa_ctx | "github.ref" => "refs/heads/qa-experimental"}
      assert {:ok, true} === IfEvaluator.evaluate(@deploy_qa_if, ctx)
    end

    test "deploy-qa gate does NOT fire on main branch" do
      assert {:ok, false} === IfEvaluator.evaluate(@deploy_qa_if, @main_ctx)
    end
  end

  describe "evaluate/2 — bad input" do
    test "nil source returns :unknown" do
      assert :unknown === IfEvaluator.evaluate(nil, %{})
    end

    test "garbage source returns :unknown" do
      assert :unknown === IfEvaluator.evaluate("???", %{})
    end

    test "unterminated string returns :unknown" do
      assert :unknown === IfEvaluator.evaluate("'unterminated", %{})
    end
  end
end
