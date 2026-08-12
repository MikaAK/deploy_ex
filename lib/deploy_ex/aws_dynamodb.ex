defmodule DeployEx.AwsDynamodb do
  alias ExAws.Dynamo

  # ex_aws_dynamo's Dynamo.list_tables/0 wraps ListTables with no way to pass
  # ExclusiveStartTableName, so the raw JSON operation is built by hand to page through it.
  @namespace "DynamoDB_20120810"

  @type table_res :: %{table_name: String.t(), table_status: String.t()}

  @spec create_table(String.t(), String.t(), String.t(), String.t(), Keyword.t()) :: ErrorMessage.t_res(any)
  def create_table(region \\ DeployEx.Config.aws_region(), table_name, key_name, key_type, opts \\ []) do
    opts = Keyword.put_new(opts, :billing_mode, :pay_per_request)

    case ExAws.request(
      Dynamo.create_table(table_name, key_name, %{key_name => key_type}, 1, 1, opts[:billing_mode]),
      region: region
    ) do
      {:ok, _} -> :ok
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{table: table_name})}
    end
  end

  @doc """
  Every DynamoDB table name in the region, following pagination to completion.

  ListTables caps a response (default 100) and signals more via `LastEvaluatedTableName`. A
  single request therefore truncates silently on an account with many tables — it returns
  `{:ok, partial}`, not an error. `Dynamo.list_tables/0` has no way to pass
  `ExclusiveStartTableName`, so pages are requested via a hand-built JSON operation instead.
  """
  @spec list_tables() :: ErrorMessage.t_res([String.t()])
  @spec list_tables(String.t()) :: ErrorMessage.t_res([String.t()])
  @spec list_tables(String.t(), Keyword.t()) :: ErrorMessage.t_res([String.t()])
  def list_tables(region \\ DeployEx.Config.aws_region(), opts \\ []) do
    list_tables_page(region, opts, %{}, [])
  end

  defp list_tables_page(region, opts, data, acc) do
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    case request_fn.(list_tables_operation(data), region: region) do
      {:ok, %{"TableNames" => table_names} = body} ->
        accumulated = acc ++ table_names

        case body["LastEvaluatedTableName"] do
          name when is_binary(name) and name !== "" ->
            list_tables_page(region, opts, %{"ExclusiveStartTableName" => name}, accumulated)

          _no_more_pages ->
            {:ok, accumulated}
        end

      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{region: region})}
    end
  end

  defp list_tables_operation(data) do
    ExAws.Operation.JSON.new(:dynamodb, %{
      data: data,
      headers: [
        {"x-amz-target", "#{@namespace}.ListTables"},
        {"content-type", "application/x-amz-json-1.0"}
      ]
    })
  end

  @spec describe_table(String.t()) :: ErrorMessage.t_res(table_res)
  @spec describe_table(String.t(), String.t()) :: ErrorMessage.t_res(table_res)
  def describe_table(region \\ DeployEx.Config.aws_region(), table_name) do
    case ExAws.request(Dynamo.describe_table(table_name), region: region) do
      {:ok, %{"Table" => table}} ->
        {:ok, %{
          table_name: table["TableName"],
          table_status: table["TableStatus"]
        }}
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{region: region, table: table_name})}
    end
  end

  def delete_table(region \\ DeployEx.Config.aws_region(), table_name) do
    case ExAws.request(Dynamo.delete_table(table_name), region: region) do
      {:ok, _} -> :ok
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{region: region, table: table_name})}
    end
  end

  defp handle_error(400, message, %{table: table_name}) do
    cond do
      String.contains?(message, "already exists") ->
        ErrorMessage.conflict("table already exists", %{table: table_name, message: message})

      String.contains?(message, "ValidationException") ->
        ErrorMessage.bad_request("invalid table configuration", %{table: table_name, message: message})

      true ->
        ErrorMessage.bad_request(message, %{table: table_name})
    end
  end

  defp handle_error(404, message, %{table: table_name}) do
    ErrorMessage.not_found("table not found", %{table: table_name, message: message})
  end

  defp handle_error(code, message, %{region: region, table: table_name}) do
    %ErrorMessage{
      code: ErrorMessage.http_code_reason_atom(code),
      message: message,
      details: %{region: region, table: table_name}
    }
  end

  defp handle_error(code, message, %{region: region}) do
    %ErrorMessage{
      code: ErrorMessage.http_code_reason_atom(code),
      message: message,
      details: %{region: region}
    }
  end
end
