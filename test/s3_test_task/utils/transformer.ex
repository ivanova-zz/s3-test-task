defmodule S3TestTask.Utils.TransformerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias S3TestTask.Utils.Transformer
  alias S3TestTask.RedshiftRepo, as: Repo
  alias S3TestTask.Utils.EtlLog

  setup :verify_on_exit!

  # Stub EtlLog by default — we verify it explicitly where needed
  setup do
    stub(EtlLog, :log_success, fn _, _, _, _ -> {:ok, %Postgrex.Result{}} end)
    stub(EtlLog, :log_error, fn _, _, _, _ -> {:ok, %Postgrex.Result{}} end)
    :ok
  end

  # Helper: expect N successful Repo.query calls + 1 DROP TABLE
  defp expect_queries_ok(n) do
    # n dimension/fact queries + 1 DROP TABLE at the end
    expect(Repo, :query, n + 1, fn _sql ->
      {:ok, %Postgrex.Result{num_rows: 10}}
    end)
  end

  # ═══════════════════════════════════════════════
  # Routing by filename
  # ═══════════════════════════════════════════════

  describe "transform/2 routing" do
    test "routes collision file" do
      # collision: dim_location, dim_weather, dim_junction, fact_collision = 4 + DROP
      expect_queries_ok(4)

      assert {:ok, msg} = Transformer.transform("collision2017-2022.csv", "stg_collision")
      assert msg =~ "collision"
    end

    test "routes vehicle file" do
      # vehicle: dim_vehicle_type, dim_manoeuvre, dim_impact, dim_person, fact_vehicle = 5 + DROP
      expect_queries_ok(5)

      assert {:ok, msg} = Transformer.transform("vehicle2017-2022.csv", "stg_vehicle")
      assert msg =~ "vehicle"
    end

    test "routes casualty file" do
      # casualty: dim_casualty_type, dim_person, fact_casualty = 3 + DROP
      expect_queries_ok(3)

      assert {:ok, msg} = Transformer.transform("casualty2017-2022.csv", "stg_casualty")
      assert msg =~ "casualty"
    end

    test "routes vehicle-index file" do
      # code_lookup: 1 INSERT + DROP
      expect_queries_ok(1)

      assert {:ok, msg} = Transformer.transform("vehicle-index.csv", "stg_vehicle_index")
      assert msg =~ "dim_code_lookup"
    end

    test "routes prefixed filenames correctly" do
      expect_queries_ok(1)

      assert {:ok, _} =
               Transformer.transform("abc123_vehicle-index.csv", "stg_vi")
    end

    test "returns error for unknown file" do
      assert {:error, msg} = Transformer.transform("random.csv", "stg_random")
      assert msg =~ "unknown file"
    end
  end

  # ═══════════════════════════════════════════════
  # Collision transform
  # ═══════════════════════════════════════════════

  describe "collision transform" do
    test "executes all 4 steps with correct SQL" do
      sqls = []

      expect(Repo, :query, 5, fn sql ->
        send(self(), {:sql, sql})
        {:ok, %Postgrex.Result{num_rows: 5}}
      end)

      {:ok, _} = Transformer.transform("collision2017-2022.csv", "stg_coll")

      # Collect all SQL statements
      sqls =
        Enum.reduce(1..5, [], fn _, acc ->
          receive do
            {:sql, sql} -> [sql | acc]
          after
            100 -> acc
          end
        end)
        |> Enum.reverse()

      assert Enum.any?(sqls, &(&1 =~ "dim_location"))
      assert Enum.any?(sqls, &(&1 =~ "dim_weather"))
      assert Enum.any?(sqls, &(&1 =~ "dim_junction"))
      assert Enum.any?(sqls, &(&1 =~ "fact_collision"))
      assert Enum.any?(sqls, &(&1 =~ "DROP TABLE"))
    end

    test "stops on first step failure" do
      # dim_location fails
      expect(Repo, :query, fn sql ->
        assert sql =~ "dim_location"
        {:error, %Postgrex.Error{message: "relation does not exist"}}
      end)

      assert {:error, _} = Transformer.transform("collision2017-2022.csv", "stg_coll")
    end

    test "stops when middle step fails" do
      expect(Repo, :query, 2, fn sql ->
        if sql =~ "dim_weather" do
          {:error, %Postgrex.Error{message: "column not found"}}
        else
          {:ok, %Postgrex.Result{num_rows: 3}}
        end
      end)

      assert {:error, _} = Transformer.transform("collision2017-2022.csv", "stg_coll")
    end
  end

  # ═══════════════════════════════════════════════
  # Vehicle transform
  # ═══════════════════════════════════════════════

  describe "vehicle transform" do
    test "executes all 5 steps" do
      expect(Repo, :query, 6, fn sql ->
        send(self(), {:sql, sql})
        {:ok, %Postgrex.Result{num_rows: 2}}
      end)

      {:ok, _} = Transformer.transform("vehicle2017-2022.csv", "stg_veh")

      sqls =
        Enum.reduce(1..6, [], fn _, acc ->
          receive do
            {:sql, sql} -> [sql | acc]
          after
            100 -> acc
          end
        end)

      assert Enum.any?(sqls, &(&1 =~ "dim_vehicle_type"))
      assert Enum.any?(sqls, &(&1 =~ "dim_manoeuvre"))
      assert Enum.any?(sqls, &(&1 =~ "dim_impact"))
      assert Enum.any?(sqls, &(&1 =~ "dim_person"))
      assert Enum.any?(sqls, &(&1 =~ "fact_vehicle"))
    end

    test "stops on dim_impact failure" do
      call_count = :counters.new(1, [:atomics])

      expect(Repo, :query, 3, fn sql ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        if n == 3 do
          {:error, %Postgrex.Error{message: "impact error"}}
        else
          {:ok, %Postgrex.Result{num_rows: 1}}
        end
      end)

      assert {:error, _} = Transformer.transform("vehicle2017-2022.csv", "stg_veh")
    end
  end

  # ═══════════════════════════════════════════════
  # Casualty transform
  # ═══════════════════════════════════════════════

  describe "casualty transform" do
    test "executes all 3 steps" do
      expect(Repo, :query, 4, fn sql ->
        send(self(), {:sql, sql})
        {:ok, %Postgrex.Result{num_rows: 7}}
      end)

      {:ok, _} = Transformer.transform("casualty2017-2022.csv", "stg_cas")

      sqls =
        Enum.reduce(1..4, [], fn _, acc ->
          receive do
            {:sql, sql} -> [sql | acc]
          after
            100 -> acc
          end
        end)

      assert Enum.any?(sqls, &(&1 =~ "dim_casualty_type"))
      assert Enum.any?(sqls, &(&1 =~ "dim_person"))
      assert Enum.any?(sqls, &(&1 =~ "fact_casualty"))
    end
  end

  # ═══════════════════════════════════════════════
  # Code lookup (vehicle-index)
  # ═══════════════════════════════════════════════

  describe "code lookup transform" do
    test "inserts into dim_code_lookup" do
      expect(Repo, :query, 2, fn sql ->
        send(self(), {:sql, sql})
        {:ok, %Postgrex.Result{num_rows: 50}}
      end)

      {:ok, msg} = Transformer.transform("vehicle-index.csv", "stg_vi")
      assert msg =~ "dim_code_lookup"

      assert_received {:sql, sql}
      assert sql =~ "INSERT INTO dim_code_lookup"
      assert sql =~ "stg_vi"
    end
  end

  # ═══════════════════════════════════════════════
  # ETL logging
  # ═══════════════════════════════════════════════

  describe "ETL logging" do
    test "logs success on happy path" do
      expect_queries_ok(1)

      expect(EtlLog, :log_success, fn filename, stg, msg, duration ->
        assert filename == "vehicle-index.csv"
        assert stg == "stg_vi"
        assert is_binary(msg)
        assert is_integer(duration) and duration >= 0
        {:ok, %Postgrex.Result{}}
      end)

      Transformer.transform("vehicle-index.csv", "stg_vi")
    end

    test "logs error on failure" do
      expect(Repo, :query, fn _sql ->
        {:error, %Postgrex.Error{message: "boom"}}
      end)

      expect(EtlLog, :log_error, fn filename, stg, _reason, duration ->
        assert filename == "vehicle-index.csv"
        assert stg == "stg_vi"
        assert is_integer(duration)
        {:ok, %Postgrex.Result{}}
      end)

      Transformer.transform("vehicle-index.csv", "stg_vi")
    end
  end

  # ═══════════════════════════════════════════════
  # Staging table cleanup
  # ═══════════════════════════════════════════════

  describe "staging table cleanup" do
    test "drops staging table on success" do
      expect(Repo, :query, 2, fn sql ->
        send(self(), {:sql, sql})
        {:ok, %Postgrex.Result{num_rows: 1}}
      end)

      Transformer.transform("vehicle-index.csv", "stg_cleanup_test")

      sqls =
        Enum.reduce(1..2, [], fn _, acc ->
          receive do
            {:sql, sql} -> [sql | acc]
          after
            100 -> acc
          end
        end)

      assert Enum.any?(sqls, &(&1 =~ "DROP TABLE IF EXISTS stg_cleanup_test"))
    end

    test "does NOT drop staging table on failure" do
      expect(Repo, :query, fn _sql ->
        {:error, %Postgrex.Error{message: "fail"}}
      end)

      Transformer.transform("vehicle-index.csv", "stg_no_drop")

      refute_received {:sql, "DROP TABLE" <> _}
    end
  end

  # ═══════════════════════════════════════════════
  # SQL references staging table
  # ═══════════════════════════════════════════════

  describe "SQL uses staging table name" do
    test "collision queries reference the staging table" do
      expect(Repo, :query, 5, fn sql ->
        if sql =~ "DROP TABLE" do
          :ok
        else
          assert sql =~ "my_stg_table"
        end

        {:ok, %Postgrex.Result{num_rows: 1}}
      end)

      Transformer.transform("collision2017-2022.csv", "my_stg_table")
    end

    test "vehicle queries reference the staging table" do
      expect(Repo, :query, 6, fn sql ->
        if sql =~ "DROP TABLE" do
          :ok
        else
          assert sql =~ "veh_stg_99"
        end

        {:ok, %Postgrex.Result{num_rows: 1}}
      end)

      Transformer.transform("vehicle2017-2022.csv", "veh_stg_99")
    end

    test "casualty queries reference the staging table" do
      expect(Repo, :query, 4, fn sql ->
        if sql =~ "DROP TABLE" do
          :ok
        else
          assert sql =~ "cas_stg_42"
        end

        {:ok, %Postgrex.Result{num_rows: 1}}
      end)

      Transformer.transform("casualty2017-2022.csv", "cas_stg_42")
    end
  end
end