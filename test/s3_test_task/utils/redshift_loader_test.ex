defmodule S3TestTask.Utils.RedshiftLoaderTest do
  use ExUnit.Case, async: false
  use Mimic

  alias S3TestTask.Utils.RedshiftLoader

  setup :verify_on_exit!

  @csv_body """
  id,name,age,score,date_joined,active
  1,Alice,30,99.5,2024-01-15,true
  2,Bob,25,87.3,2024-02-20,false
  3,Carol,,100.0,2024-03-10,yes
  """

  # Helper: sets up sequential ExAws.request expectations for a full load_file flow
  # 1. S3 get_object (analyze CSV)
  # 2. execute_sql (CREATE TABLE) -> statement_id
  # 3. get_statement_status (CREATE) -> FINISHED
  # 4. execute_sql (COPY) -> statement_id
  # 5. get_statement_status (COPY) -> FINISHED
  defp expect_full_happy_path do
    ExAws
    |> expect(:request, fn %ExAws.Operation.S3{} ->
      {:ok, %{body: @csv_body}}
    end)
    |> expect(:request, fn %ExAws.Operation.JSON{} ->
      {:ok, %{"Id" => "stmt-create-001"}}
    end)
    |> expect(:request, fn %ExAws.Operation.JSON{} ->
      {:ok, %{"Status" => "FINISHED"}}
    end)
    |> expect(:request, fn %ExAws.Operation.JSON{} ->
      {:ok, %{"Id" => "stmt-copy-001"}}
    end)
    |> expect(:request, fn %ExAws.Operation.JSON{} ->
      {:ok, %{"Status" => "FINISHED"}}
    end)
  end

  # ═══════════════════════════════════════════════
  # load_file/1 — happy path
  # ═══════════════════════════════════════════════

  describe "load_file/1 happy path" do
    test "returns table name and statement_id" do
      expect_full_happy_path()

      assert {:ok, %{table: table, statement_id: _id}} =
               RedshiftLoader.load_file("uploads/2025/my-data.csv")

      assert table == "raw_my_data"
    end

    test "derives correct table name from key" do
      expect_full_happy_path()

      {:ok, %{table: table}} =
        RedshiftLoader.load_file("uploads/2026-02-18/abc123_collision2017-2022.csv")

      assert table == "raw_abc123_collision2017_2022"
    end
  end

  # ═══════════════════════════════════════════════
  # load_file/1 — CSV analysis failure
  # ═══════════════════════════════════════════════

  describe "load_file/1 CSV analysis failure" do
    test "returns error when S3 fetch fails" do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:error, {:http_error, 404, "Not Found"}}
      end)

      assert {:error, {:http_error, 404, "Not Found"}} =
               RedshiftLoader.load_file("uploads/missing.csv")
    end
  end

  # ═══════════════════════════════════════════════
  # load_file/1 — CREATE TABLE failure
  # ═══════════════════════════════════════════════

  describe "load_file/1 CREATE TABLE failure" do
    test "returns error when execute_sql fails" do
      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} ->
        {:ok, %{body: @csv_body}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:error, {:http_error, 500, "Internal Error"}}
      end)

      assert {:error, _} = RedshiftLoader.load_file("uploads/data.csv")
    end

    test "returns error when CREATE statement fails" do
      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} ->
        {:ok, %{body: @csv_body}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Id" => "stmt-create-fail"}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Status" => "FAILED"}}
      end)

      assert {:error, :statement_failed} = RedshiftLoader.load_file("uploads/data.csv")
    end
  end

  # ═══════════════════════════════════════════════
  # load_file/1 — COPY failure
  # ═══════════════════════════════════════════════

  describe "load_file/1 COPY failure" do
    test "returns error when COPY execute fails" do
      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} ->
        {:ok, %{body: @csv_body}}
      end)
        # CREATE TABLE
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Id" => "stmt-create"}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Status" => "FINISHED"}}
      end)
        # COPY fails
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:error, {:http_error, 403, "Access Denied"}}
      end)

      assert {:error, {:http_error, 403, _}} = RedshiftLoader.load_file("uploads/data.csv")
    end

    test "returns error when COPY statement status is FAILED" do
      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} ->
        {:ok, %{body: @csv_body}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Id" => "stmt-create"}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Status" => "FINISHED"}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Id" => "stmt-copy"}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Status" => "FAILED"}}
      end)

      assert {:error, :statement_failed} = RedshiftLoader.load_file("uploads/data.csv")
    end
  end

  # ═══════════════════════════════════════════════
  # load_file/1 — polling / wait_for_completion
  # ═══════════════════════════════════════════════

  describe "load_file/1 statement polling" do
    test "waits through SUBMITTED/STARTED before FINISHED" do
      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} ->
        {:ok, %{body: @csv_body}}
      end)
        # CREATE TABLE
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Id" => "stmt-create"}}
      end)
        # Poll: SUBMITTED -> STARTED -> FINISHED
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Status" => "SUBMITTED"}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Status" => "STARTED"}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Status" => "FINISHED"}}
      end)
        # COPY
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Id" => "stmt-copy"}}
      end)
      |> expect(:request, fn %ExAws.Operation.JSON{} ->
        {:ok, %{"Status" => "FINISHED"}}
      end)

      assert {:ok, _} = RedshiftLoader.load_file("uploads/data.csv")
    end
  end

  # ═══════════════════════════════════════════════
  # Column type inference (tested via CREATE TABLE SQL)
  # ═══════════════════════════════════════════════

  describe "column type inference" do
    test "infers BIGINT for integer columns" do
      csv = "count\n1\n2\n3\n"

      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} -> {:ok, %{body: csv}} end)
      |> expect(:request, fn %ExAws.Operation.JSON{data: %{"Sql" => sql}} ->
        assert sql =~ "count BIGINT"
        {:ok, %{"Id" => "s1"}}
      end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Id" => "s2"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)

      RedshiftLoader.load_file("uploads/nums.csv")
    end

    test "infers DECIMAL for float columns" do
      csv = "price\n9.99\n12.50\n"

      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} -> {:ok, %{body: csv}} end)
      |> expect(:request, fn %ExAws.Operation.JSON{data: %{"Sql" => sql}} ->
        assert sql =~ "price DECIMAL(18,4)"
        {:ok, %{"Id" => "s1"}}
      end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Id" => "s2"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)

      RedshiftLoader.load_file("uploads/prices.csv")
    end

    test "infers DATE for date columns" do
      csv = "joined\n2024-01-15\n2024-02-20\n"

      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} -> {:ok, %{body: csv}} end)
      |> expect(:request, fn %ExAws.Operation.JSON{data: %{"Sql" => sql}} ->
        assert sql =~ "joined DATE"
        {:ok, %{"Id" => "s1"}}
      end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Id" => "s2"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)

      RedshiftLoader.load_file("uploads/dates.csv")
    end

    test "infers BOOLEAN for boolean columns" do
      csv = "active\ntrue\nfalse\nyes\n"

      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} -> {:ok, %{body: csv}} end)
      |> expect(:request, fn %ExAws.Operation.JSON{data: %{"Sql" => sql}} ->
        assert sql =~ "active BOOLEAN"
        {:ok, %{"Id" => "s1"}}
      end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Id" => "s2"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)

      RedshiftLoader.load_file("uploads/bools.csv")
    end

    test "infers VARCHAR for text columns" do
      csv = "name\nAlice\nBob\nCarol\n"

      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} -> {:ok, %{body: csv}} end)
      |> expect(:request, fn %ExAws.Operation.JSON{data: %{"Sql" => sql}} ->
        assert sql =~ ~r/name VARCHAR\(\d+\)/
        {:ok, %{"Id" => "s1"}}
      end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Id" => "s2"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)

      RedshiftLoader.load_file("uploads/names.csv")
    end

    test "infers VARCHAR(65535) for long text" do
      long = String.duplicate("x", 300)
      csv = "desc\n#{long}\n"

      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} -> {:ok, %{body: csv}} end)
      |> expect(:request, fn %ExAws.Operation.JSON{data: %{"Sql" => sql}} ->
        assert sql =~ "VARCHAR(65535)"
        {:ok, %{"Id" => "s1"}}
      end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Id" => "s2"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)

      RedshiftLoader.load_file("uploads/long.csv")
    end
  end

  # ═══════════════════════════════════════════════
  # Column name sanitization (tested via CREATE TABLE SQL)
  # ═══════════════════════════════════════════════

  describe "column name sanitization" do
    test "sanitizes special characters and leading digits" do
      csv = "First Name,2nd Col,  spaces  ,normal\nA,B,C,D\n"

      ExAws
      |> expect(:request, fn %ExAws.Operation.S3{} -> {:ok, %{body: csv}} end)
      |> expect(:request, fn %ExAws.Operation.JSON{data: %{"Sql" => sql}} ->
        assert sql =~ "first_name"
        assert sql =~ "col_2nd_col"
        assert sql =~ "spaces"
        assert sql =~ "normal"
        {:ok, %{"Id" => "s1"}}
      end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Id" => "s2"}} end)
      |> expect(:request, fn _ -> {:ok, %{"Status" => "FINISHED"}} end)

      RedshiftLoader.load_file("uploads/weird_headers.csv")
    end
  end

  # ═══════════════════════════════════════════════
  # Config helpers
  # ═══════════════════════════════════════════════

  describe "config helpers" do
    test "workgroup reads from config" do
      assert RedshiftLoader.workgroup() ==
               Application.get_env(:s3_test_task, :redshift_workgroup)
    end

    test "database reads from config" do
      assert RedshiftLoader.database() ==
               Application.get_env(:s3_test_task, :redshift_database)
    end

    test "iam_role reads from config" do
      assert RedshiftLoader.iam_role() ==
               Application.get_env(:s3_test_task, :redshift_iam_role)
    end

    test "bucket reads from config" do
      assert RedshiftLoader.bucket() ==
               Application.get_env(:s3_test_task, :s3_bucket)
    end
  end
end