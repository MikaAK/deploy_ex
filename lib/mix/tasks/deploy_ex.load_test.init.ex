defmodule Mix.Tasks.DeployEx.LoadTest.Init do
  use Mix.Task

  @shortdoc "Scaffolds k6 test scripts for an app"
  @moduledoc """
  Creates a k6 test script directory and template for the specified application.

  ## Example
  ```bash
  mix deploy_ex.load_test.init my_app
  ```

  Creates `deploys/k6/scripts/<app_name>/load_test.js` with a parametrized
  k6 test script that can be customized for your application.
  """

  @script_template """
  import http from 'k6/http';
  import { check, sleep } from 'k6';

  export const options = {
    stages: [
      { duration: '30s', target: 20 },
      { duration: '1m', target: 20 },
      { duration: '10s', target: 0 },
    ],
  };

  export default function () {
    const url = __ENV.TARGET_URL || 'http://localhost:4000/health';
    const res = http.get(url);

    check(res, {
      'status is 200': (r) => r.status === 200,
      'response time < 500ms': (r) => r.timings.duration < 500,
    });

    sleep(1);
  }
  """

  def run(args) do
    case args do
      [app_name | _] ->
        scaffold(app_name)

      [] ->
        Mix.raise("App name is required: mix deploy_ex.load_test.init <app_name>")
    end
  end

  defp scaffold(app_name) do
    dir = Path.join(["deploys", "k6", "scripts", app_name])
    script_path = Path.join(dir, "load_test.js")

    if File.exists?(script_path) do
      Mix.shell().info([:yellow, "Script already exists at #{script_path}"])

      unless Mix.shell().yes?("Overwrite?") do
        Mix.raise("Aborted")
      end
    end

    File.mkdir_p!(dir)
    File.write!(script_path, @script_template)

    Mix.shell().info([
      :green, "✓ ", :reset, "Created ", :cyan, script_path, :reset, "\n\n",
      "Edit the script then run:\n",
      "  mix deploy_ex.load_test.upload #{app_name}\n",
      "  mix deploy_ex.load_test.exec #{app_name} --target-url http://your-app:4000\n"
    ])
  end
end
