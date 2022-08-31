defmodule DeployEx.Utils do
  @type status_tuple :: {:ok, any} | {:error, any}

  @doc """
  Converts a list of status tuples from a task `({:ok, any} | {:error, any})` into a singular
  status tuple with all errors or results in an array

  ### Example

      iex> SharedUtils.Enum.reduce_task_status_tuples([{:ok, {:ok, 1}}, {:ok, {:ok, 2}}])
      {:ok, [1, 2]}

      iex> SharedUtils.Enum.reduce_task_status_tuples([{:ok, {:error, 1}}, {:ok, {:ok, 2}}, {:ok, {:error, 3}}])
      {:error, [1, 3]}

      iex> SharedUtils.Enum.reduce_task_status_tuples([{:exit, :badarith}, {:ok, {:ok, 2}}, {:ok, {:error, 3}}])
      {:error, [:badarith, 3]}
  """
  @spec reduce_task_status_tuples(Enumerable.t()) :: status_tuple
  def reduce_task_status_tuples(status_tuples) do
    {status, res} =
      Enum.reduce(status_tuples, {:ok, []}, fn
        {:ok, {:ok, _}}, {:error, _} = e -> e
        {:ok, {:ok, record}}, {:ok, acc} -> {:ok, [record | acc]}
        {:ok, {:error, error}}, {:ok, _} -> {:error, [error]}
        {:ok, {:error, e}}, {:error, error_acc} -> {:error, [e | error_acc]}
        {:exit, reason}, {:ok, _} -> {:error, [reason]}
        {:exit, reason}, {:error, error_acc} -> {:error, [reason | error_acc]}
      end)

    {status, Enum.reverse(res)}
  end
end
