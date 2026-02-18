defmodule S3TestTask.Utils.RedshiftLoader do
  @moduledoc """
  Load CSV files from S3 to Redshift Serverless.
  """

  require Logger

  def workgroup, do: Application.get_env(:s3_test_task, :redshift_workgroup)
  def database, do: Application.get_env(:s3_test_task, :redshift_database)
  def iam_role, do: Application.get_env(:s3_test_task, :redshift_iam_role)
  def bucket, do: Application.get_env(:s3_test_task, :s3_bucket)

  @doc """
  Load CSV file from S3 to Redshift table.
  Creates table if not exists based on filename.
  """
  def load_file(s3_key) do
    table_name = derive_table_name(s3_key)
    s3_path = "s3://#{bucket()}/#{s3_key}"

    Logger.info("Loading #{s3_path} to table #{table_name}")

    with {:ok, _} <- create_table_if_not_exists(table_name, s3_key),
         {:ok, result} <- copy_from_s3(table_name, s3_path) do
      {:ok, %{table: table_name, statement_id: result}}
    end
  end

  defp derive_table_name(s3_key) do
    s3_key
    |> Path.basename()
    |> String.replace(~r/\.csv$/i, "")
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.downcase()
    |> then(&"raw_#{&1}")
  end

  defp create_table_if_not_exists(table_name, s3_key) do
    case analyze_csv(s3_key) do
      {:ok, columns} ->
        columns_sql =
          columns
          |> Enum.map(fn {name, type} -> "#{name} #{type}" end)
          |> Enum.join(", ")

        sql = "CREATE TABLE IF NOT EXISTS #{table_name} (#{columns_sql});"

        Logger.info("Creating table: #{sql}")
        execute_sql(sql)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp analyze_csv(s3_key) do
    bucket = Application.get_env(:s3_test_task, :s3_bucket)
    case ExAws.S3.get_object(bucket, s3_key, range: "bytes=0-51200") |> ExAws.request() do
      {:ok, %{body: body}} ->
        lines = String.split(body, ~r/\r?\n/, trim: true)
        [header_line | data_lines] = lines

        headers = parse_csv_line(header_line)

        sample_data = Enum.take(data_lines, 10) |> Enum.map(&parse_csv_line/1)

        columns =
          headers
          |> Enum.with_index()
          |> Enum.map(fn {header, idx} ->
            values = Enum.map(sample_data, fn row -> Enum.at(row, idx) end)
            type = infer_type(values)
            {sanitize_column_name(header), type}
          end)

        {:ok, columns}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_csv_line(line) do
    line
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.replace(&1, "\"", ""))
  end

  defp infer_type(values) do
    values = Enum.reject(values, &is_nil/1) |> Enum.reject(&(&1 == ""))

    cond do
      Enum.empty?(values) ->
        "VARCHAR(255)"

      Enum.all?(values, &integer?/1) ->
        "BIGINT"

      Enum.all?(values, &float?/1) ->
        "DECIMAL(18,4)"

      Enum.all?(values, &date?/1) ->
        "DATE"

      Enum.all?(values, &boolean?/1) ->
        "BOOLEAN"

      true ->
        max_len = values |> Enum.map(&String.length/1) |> Enum.max(fn -> 255 end)

        cond do
          max_len <= 50 -> "VARCHAR(100)"
          max_len <= 255 -> "VARCHAR(500)"
          true -> "VARCHAR(65535)"
        end
    end
  end

  defp integer?(value) do
    case Integer.parse(value) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp float?(value) do
    case Float.parse(value) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp date?(value) do
    # Проверяем форматы: YYYY-MM-DD, DD/MM/YYYY, etc.
    String.match?(value, ~r/^\d{4}-\d{2}-\d{2}$/) or
      String.match?(value, ~r/^\d{2}\/\d{2}\/\d{4}$/)
  end

  defp boolean?(value) do
    String.downcase(value) in ["true", "false", "yes", "no", "1", "0"]
  end

  defp copy_from_s3(table_name, s3_path) do
    sql = """
    COPY #{table_name}
    FROM '#{s3_path}'
    IAM_ROLE '#{iam_role()}'
    FORMAT CSV
    IGNOREHEADER 1
    DELIMITER ','
    REGION 'eu-central-1';
    """

    execute_sql(sql)
  end

  defp execute_sql(sql) do
    request = %{
      "WorkgroupName" => workgroup(),
      "Database" => database(),
      "Sql" => sql
    }

    operation = %ExAws.Operation.JSON{
      http_method: :post,
      service: :"redshift-data",
      headers: [
        {"x-amz-target", "RedshiftData.ExecuteStatement"},
        {"content-type", "application/x-amz-json-1.1"}
      ],
      data: request
    }

    case ExAws.request(operation) do
      {:ok, %{"Id" => statement_id}} ->
        wait_for_completion(statement_id)

      {:error, reason} ->
        Logger.error("Redshift SQL failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp wait_for_completion(statement_id, attempts \\ 30) do
    if attempts <= 0 do
      {:error, :timeout}
    else
      case get_statement_status(statement_id) do
        {:ok, "FINISHED"} ->
          {:ok, statement_id}

        {:ok, "FAILED"} ->
          Logger.error("Redshift statement failed")
          {:error, :statement_failed}

        {:ok, status} when status in ["SUBMITTED", "PICKED", "STARTED"] ->
          Process.sleep(2000)
          wait_for_completion(statement_id, attempts - 1)

        {:error, _} = error ->
          error
      end
    end
  end

  defp get_statement_status(statement_id) do
    operation = %ExAws.Operation.JSON{
      http_method: :post,
      service: :"redshift-data",
      headers: [
        {"x-amz-target", "RedshiftData.DescribeStatement"},
        {"content-type", "application/x-amz-json-1.1"}
      ],
      data: %{"Id" => statement_id}
    }

    case ExAws.request(operation) do
      {:ok, %{"Status" => status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sanitize_column_name(name) do
    name
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
    |> ensure_valid_column_name()
  end

  defp ensure_valid_column_name(""), do: "column"

  defp ensure_valid_column_name(name) do
    if String.match?(name, ~r/^[0-9]/) do
      "col_#{name}"
    else
      name
    end
  end
end
