defmodule S3TestTask.Utils.EtlLog do
  alias S3TestTask.RedshiftRepo, as: Repo

  def log_success(filename, staging_table, message, duration_ms) do
    Repo.query(
      """
      INSERT INTO etl_log (filename, staging_table, status, message, duration_ms)
      VALUES ($1, $2, 'success', $3, $4)
      """,
      [filename, staging_table, message, duration_ms]
    )
  end

  def log_error(filename, staging_table, reason, duration_ms) do
    Repo.query(
      """
      INSERT INTO etl_log (filename, staging_table, status, message, duration_ms)
      VALUES ($1, $2, 'error', $3, $4)
      """,
      [filename, staging_table, inspect(reason), duration_ms]
    )
  end

  def transformed?(filename) do
    case Repo.query(
           "SELECT 1 FROM etl_log WHERE filename = $1 AND status = 'success' LIMIT 1",
           [filename]
         ) do
      {:ok, %{num_rows: n}} when n > 0 -> true
      _ -> false
    end
  end

  def list_transformed do
    case Repo.query("""
      SELECT filename, status, message, duration_ms, created_at
      FROM etl_log
      ORDER BY created_at DESC
    """) do
      {:ok, %{rows: rows, columns: cols}} ->
        Enum.map(rows, fn row -> Enum.zip(cols, row) |> Map.new() end)
      _ ->
        []
    end
  end

  def get_status_map do
    case Repo.query("""
      SELECT filename, status, message
      FROM etl_log
      ORDER BY filename, created_at DESC
    """) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [filename, status, message] ->
          {filename, %{status: status, message: message}}
        end)
      _ ->
        %{}
    end
  end
  
end
