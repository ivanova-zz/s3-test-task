defmodule S3TestTask.Utils.EtlLogTest do
  use ExUnit.Case, async: false
  use Mimic

  alias S3TestTask.Utils.EtlLog
  alias S3TestTask.RedshiftRepo, as: Repo

  setup :verify_on_exit!

  # ═══════════════════════════════════════════════
  # log_success/4
  # ═══════════════════════════════════════════════

  describe "log_success/4" do
    test "inserts success record" do
      expect(Repo, :query, fn sql, params ->
        assert sql =~ "INSERT INTO etl_log"
        assert sql =~ "'success'"
        assert params == ["collisions.csv", "stg_collisions", "Loaded 500 rows", 1234]
        {:ok, %Postgrex.Result{num_rows: 1}}
      end)

      assert {:ok, _} = EtlLog.log_success("collisions.csv", "stg_collisions", "Loaded 500 rows", 1234)
    end
  end

  # ═══════════════════════════════════════════════
  # log_error/4
  # ═══════════════════════════════════════════════

  describe "log_error/4" do
    test "inserts error record with inspected reason" do
      expect(Repo, :query, fn sql, params ->
        assert sql =~ "INSERT INTO etl_log"
        assert sql =~ "'error'"

        [filename, table, message, duration] = params
        assert filename == "vehicles.csv"
        assert table == "stg_vehicles"
        assert message =~ "column mismatch"
        assert duration == 567

        {:ok, %Postgrex.Result{num_rows: 1}}
      end)

      assert {:ok, _} = EtlLog.log_error("vehicles.csv", "stg_vehicles", "column mismatch", 567)
    end

    test "inspects non-string reasons" do
      expect(Repo, :query, fn _sql, params ->
        [_, _, message, _] = params
        assert message == "{:error, :timeout}"
        {:ok, %Postgrex.Result{num_rows: 1}}
      end)

      EtlLog.log_error("f.csv", "stg", {:error, :timeout}, 100)
    end
  end

  # ═══════════════════════════════════════════════
  # transformed?/1
  # ═══════════════════════════════════════════════

  describe "transformed?/1" do
    test "returns true when success record exists" do
      expect(Repo, :query, fn sql, params ->
        assert sql =~ "SELECT 1 FROM etl_log"
        assert sql =~ "status = 'success'"
        assert params == ["collisions.csv"]
        {:ok, %Postgrex.Result{num_rows: 1, rows: [[1]]}}
      end)

      assert EtlLog.transformed?("collisions.csv") == true
    end

    test "returns false when no success record" do
      expect(Repo, :query, fn _sql, _params ->
        {:ok, %Postgrex.Result{num_rows: 0, rows: []}}
      end)

      assert EtlLog.transformed?("missing.csv") == false
    end

    test "returns false on query error" do
      expect(Repo, :query, fn _sql, _params ->
        {:error, %Postgrex.Error{}}
      end)

      assert EtlLog.transformed?("broken.csv") == false
    end
  end

  # ═══════════════════════════════════════════════
  # list_transformed/0
  # ═══════════════════════════════════════════════

  describe "list_transformed/0" do
    test "returns list of maps from rows" do
      expect(Repo, :query, fn sql ->
        assert sql =~ "SELECT filename, status, message, duration_ms, created_at"
        {:ok,
          %Postgrex.Result{
            columns: ["filename", "status", "message", "duration_ms", "created_at"],
            rows: [
              ["collisions.csv", "success", "done", 1200, ~N[2025-01-01 12:00:00]],
              ["vehicles.csv", "error", "bad col", 300, ~N[2025-01-02 13:00:00]]
            ]
          }}
      end)

      result = EtlLog.list_transformed()

      assert length(result) == 2
      assert Enum.at(result, 0)["filename"] == "collisions.csv"
      assert Enum.at(result, 0)["status"] == "success"
      assert Enum.at(result, 1)["filename"] == "vehicles.csv"
      assert Enum.at(result, 1)["status"] == "error"
    end

    test "returns empty list on error" do
      expect(Repo, :query, fn _sql ->
        {:error, %Postgrex.Error{}}
      end)

      assert EtlLog.list_transformed() == []
    end

    test "returns empty list when no rows" do
      expect(Repo, :query, fn _sql ->
        {:ok,
          %Postgrex.Result{
            columns: ["filename", "status", "message", "duration_ms", "created_at"],
            rows: []
          }}
      end)

      assert EtlLog.list_transformed() == []
    end
  end

  # ═══════════════════════════════════════════════
  # get_status_map/0
  # ═══════════════════════════════════════════════

  describe "get_status_map/0" do
    test "returns map keyed by filename" do
      expect(Repo, :query, fn sql ->
        assert sql =~ "SELECT filename, status, message"
        {:ok,
          %Postgrex.Result{
            rows: [
              ["collisions.csv", "success", "Transformed 500 rows"],
              ["vehicles.csv", "error", "column mismatch"]
            ]
          }}
      end)

      result = EtlLog.get_status_map()

      assert result == %{
               "collisions.csv" => %{status: "success", message: "Transformed 500 rows"},
               "vehicles.csv" => %{status: "error", message: "column mismatch"}
             }
    end

    test "last entry wins for duplicate filenames" do
      expect(Repo, :query, fn _sql ->
        {:ok,
          %Postgrex.Result{
            rows: [
              ["f.csv", "error", "first attempt failed"],
              ["f.csv", "success", "retry worked"]
            ]
          }}
      end)

      result = EtlLog.get_status_map()
      assert result["f.csv"].status == "success"
    end

    test "returns empty map on error" do
      expect(Repo, :query, fn _sql ->
        {:error, %Postgrex.Error{}}
      end)

      assert EtlLog.get_status_map() == %{}
    end

    test "returns empty map when no rows" do
      expect(Repo, :query, fn _sql ->
        {:ok, %Postgrex.Result{rows: []}}
      end)

      assert EtlLog.get_status_map() == %{}
    end
  end
end