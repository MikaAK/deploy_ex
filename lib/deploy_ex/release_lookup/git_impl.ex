defmodule DeployEx.ReleaseLookup.GitImpl do
  @moduledoc false

  @doc """
  Returns the list of short SHAs reachable from `branch` up to `depth` commits,
  by running `git rev-list <branch> --abbrev-commit -n <depth>`.
  """
  @spec list_shas_on_branch(branch :: String.t(), depth :: pos_integer()) ::
          {:ok, [String.t()]} | {:error, ErrorMessage.t()}
  def list_shas_on_branch(branch, depth) do
    command = "git rev-list #{branch} --abbrev-commit -n #{depth}"

    case DeployEx.Utils.run_command_with_return(command, ".") do
      {:ok, output} ->
        shas =
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 === ""))

        {:ok, shas}

      {:error, _} = error ->
        error
    end
  end
end
