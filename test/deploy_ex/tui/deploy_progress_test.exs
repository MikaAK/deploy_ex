defmodule DeployEx.TUI.DeployProgressTest do
  use ExUnit.Case, async: true

  alias DeployEx.TUI.DeployProgress

  describe "action_labels/1" do
    test "defaults to deploy wording" do
      assert DeployProgress.action_labels([]) === %{gerund: "Deploying", noun: "Deploy"}
    end

    test "honors action_gerund and action_noun overrides" do
      labels = DeployProgress.action_labels(action_gerund: "Setting Up", action_noun: "Setup")

      assert labels === %{gerund: "Setting Up", noun: "Setup"}
    end
  end
end
