defmodule DeployEx.Utils do
  @type status_tuple :: {:ok, any} | {:error, any}
  @type list_status_tuple :: {:ok, list(any)} | {:error, list(any)}

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

  @doc """
  Converts a list of status tuples `({:ok, any} | {:error, any})` into a singular
  status tuple with all errors or results in an array

  ### Example

      iex> SharedUtils.Enum.reduce_status_tuples([{:ok, 1}, {:ok, 2}, {:ok, 3}])
      {:ok, [1, 2, 3]}

      iex> SharedUtils.Enum.reduce_status_tuples([{:error, 1}, {:ok, 2}, {:error, 3}])
      {:error, [1, 3]}

      iex> SharedUtils.Enum.reduce_status_tuples([{:error, 1}, {:ok, 2}, {:ok, 3}])
      {:error, [1]}

      iex> SharedUtils.Enum.reduce_status_tuples([{:exit, 1}, {:exit, 2}, {:ok, 3}])
      {:error, [1, 2]}
  """
  @spec reduce_status_tuples(Enumerable.t()) :: list_status_tuple
  def reduce_status_tuples(status_tuples) do
    {status, res} =
      Enum.reduce(status_tuples, {:ok, []}, fn
        :ok, {:error, _} = e -> e
        {:ok, record}, {:ok, acc} -> {:ok, [record | acc]}
        :ok, {:ok, acc} -> {:ok, acc}
        {:error, error}, {:ok, _} -> {:error, [error]}
        {:error, e}, {:error, error_acc} -> {:error, [e | error_acc]}
        {:exit, error}, {:ok, _} -> {:error, [error]}
        {:exit, error}, {:error, error_acc} -> {:error, [error | error_acc]}
      end)

    {status, Enum.reverse(res)}
  end
end
