defmodule S3TestTaskWeb.UploadLive.IndexTest do
  use S3TestTaskWeb.ConnCase, async: false
  use Mimic
  import Phoenix.LiveViewTest

  alias S3TestTaskWeb.UploadLive.Index
  alias S3TestTask.Utils.S3Uploader
  alias S3TestTask.Utils.RedshiftLoader
  alias S3TestTask.Utils.Transformer
  alias S3TestTask.Utils.EtlLog

  setup :verify_on_exit!

  defp stub_defaults(_ctx \\ %{}) do
    stub(S3Uploader, :list_files, fn -> {:ok, []} end)
    stub(S3Uploader, :upload_file, fn _, _ -> {:error, :not_stubbed} end)
    stub(EtlLog, :get_status_map, fn -> %{} end)
    stub(RedshiftLoader, :load_file, fn _ -> {:error, :not_stubbed} end)
    stub(Transformer, :transform, fn _, _ -> {:error, :not_stubbed} end)
    :ok
  end

  defp s3_file(overrides \\ %{}) do
    Map.merge(
      %{key: "uploads/test.csv", name: "test.csv", size: 1024, last_modified: "2025-01-01 12:00"},
      overrides
    )
  end

  # ═══════════════════════════════════════════════
  # Mount
  # ═══════════════════════════════════════════════

  describe "mount/3" do
    setup [:stub_defaults]

    test "sets initial assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")
      assert has_element?(view, "h1", "Upload CSV Files")
      assert has_element?(view, "button", "Upload to S3")
    end

    test "loads s3 files on mount", %{conn: conn} do
      files = [s3_file(%{name: "data.csv", size: 2048})]
      stub(S3Uploader, :list_files, fn -> {:ok, files} end)

      {:ok, _view, html} = live(conn, ~p"/upload")
      assert html =~ "data.csv"
    end

    test "handles s3 list error gracefully", %{conn: conn} do
      stub(S3Uploader, :list_files, fn -> {:error, :timeout} end)

      {:ok, _view, html} = live(conn, ~p"/upload")
      assert html =~ "No files in S3"
    end

    test "loads etl statuses from log", %{conn: conn} do
      stub(EtlLog, :get_status_map, fn ->
        %{"collision2017-2022.csv" => %{status: "success", message: "done"}}
      end)

      stub(S3Uploader, :list_files, fn ->
        {:ok, [s3_file(%{name: "collision2017-2022.csv"})]}
      end)

      {:ok, _view, html} = live(conn, ~p"/upload")
      assert html =~ "Already transformed"
    end

    test "shows failed etl status", %{conn: conn} do
      stub(EtlLog, :get_status_map, fn ->
        %{"vehicle2017-2022.csv" => %{status: "error", message: "bad columns"}}
      end)

      stub(S3Uploader, :list_files, fn ->
        {:ok, [s3_file(%{name: "vehicle2017-2022.csv"})]}
      end)

      {:ok, _view, html} = live(conn, ~p"/upload")
      assert html =~ "Failed"
      assert html =~ "bad columns"
    end
  end

  # ═══════════════════════════════════════════════
  # File upload
  # ═══════════════════════════════════════════════

  describe "file upload" do
    setup [:stub_defaults]

    test "validate event is accepted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")
      assert render(view) =~ "Upload to S3"
    end

    test "successful upload shows flash", %{conn: conn} do
      expect(S3Uploader, :upload_file, fn _path, "test.csv" ->
        {:ok, %{url: "https://s3/test.csv", key: "uploads/test.csv"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/upload")

      csv = file_input(view, "#upload-form", :csv, [
        %{name: "test.csv", content: "a,b\n1,2", type: "text/csv"}
      ])

      render_upload(csv, "test.csv")
      html = view |> form("#upload-form") |> render_submit()

      assert html =~ "1 file(s) uploaded successfully"
    end

    test "failed upload collects errors", %{conn: conn} do
      expect(S3Uploader, :upload_file, fn _path, "bad.csv" ->
        {:error, :access_denied}
      end)

      {:ok, view, _html} = live(conn, ~p"/upload")

      csv = file_input(view, "#upload-form", :csv, [
        %{name: "bad.csv", content: "x", type: "text/csv"}
      ])

      render_upload(csv, "bad.csv")
      html = view |> form("#upload-form") |> render_submit()

      assert html =~ "0 file(s) uploaded successfully"
    end
  end

  # ═══════════════════════════════════════════════
  # Refresh
  # ═══════════════════════════════════════════════

  describe "refresh" do
    setup [:stub_defaults]

    test "reloads s3 file list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      expect(S3Uploader, :list_files, fn ->
        {:ok, [s3_file(%{name: "new.csv"})]}
      end)

      html = view |> element("button", "↻ Refresh") |> render_click()
      assert html =~ "new.csv"
    end
  end

  # ═══════════════════════════════════════════════
  # Load to Redshift
  # ═══════════════════════════════════════════════

  describe "load_to_redshift" do
    setup [:stub_defaults]

    test "success stores staging table", %{conn: conn} do
      f = s3_file(%{name: "collision2017-2022.csv", key: "uploads/collision2017-2022.csv"})
      stub(S3Uploader, :list_files, fn -> {:ok, [f]} end)

      expect(RedshiftLoader, :load_file, fn "uploads/collision2017-2022.csv" ->
        {:ok, %{table: "staging_collision_abc123"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/upload")

      view
      |> element(~s(button[phx-value-key="uploads/collision2017-2022.csv"]))
      |> render_click()

      Process.sleep(100)
      html = render(view)
      assert html =~ "staging_collision_abc123"
    end

    test "failure shows error flash", %{conn: conn} do
      f = s3_file()
      stub(S3Uploader, :list_files, fn -> {:ok, [f]} end)

      expect(RedshiftLoader, :load_file, fn _key ->
        {:error, "connection refused"}
      end)

      {:ok, view, _html} = live(conn, ~p"/upload")

      view
      |> element(~s(button[phx-value-key="uploads/test.csv"]))
      |> render_click()

      Process.sleep(100)
      html = render(view)
      assert html =~ "Failed"
    end
  end

  # ═══════════════════════════════════════════════
  # Transform
  # ═══════════════════════════════════════════════

  describe "transform" do
    setup [:stub_defaults]

    test "requires staging table first", %{conn: conn} do
      f = s3_file(%{name: "collision2017-2022.csv"})
      stub(S3Uploader, :list_files, fn -> {:ok, [f]} end)

      {:ok, view, _html} = live(conn, ~p"/upload")

      html = render_click(view, "transform", %{"name" => "collision2017-2022.csv"})
      assert html =~ "First load"
    end

    test "successful transform updates etl status", %{conn: conn} do
      name = "collision2017-2022.csv"
      key = "uploads/#{name}"
      f = s3_file(%{name: name, key: key})

      stub(S3Uploader, :list_files, fn -> {:ok, [f]} end)

      expect(RedshiftLoader, :load_file, fn _ ->
        {:ok, %{table: "stg_tbl"}}
      end)

      expect(Transformer, :transform, fn ^name, "stg_tbl" ->
        {:ok, "Transformed 500 rows"}
      end)

      {:ok, view, _html} = live(conn, ~p"/upload")

      # Step 1: load to redshift
      view |> element(~s(button[phx-value-key="#{key}"])) |> render_click()
      Process.sleep(100)
      render(view)

      # Step 2: transform
      view |> element(~s(button[phx-value-name="#{name}"]), "Transform") |> render_click()
      Process.sleep(100)
      html = render(view)

      assert html =~ "Already transformed"
    end

    test "failed transform shows error with retry", %{conn: conn} do
      name = "collision2017-2022.csv"
      key = "uploads/#{name}"
      f = s3_file(%{name: name, key: key})

      stub(S3Uploader, :list_files, fn -> {:ok, [f]} end)

      expect(RedshiftLoader, :load_file, fn _ ->
        {:ok, %{table: "stg_tbl"}}
      end)

      expect(Transformer, :transform, fn _, _ ->
        {:error, "column mismatch"}
      end)

      {:ok, view, _html} = live(conn, ~p"/upload")

      view |> element(~s(button[phx-value-key="#{key}"])) |> render_click()
      Process.sleep(100)
      render(view)

      view |> element(~s(button[phx-value-name="#{name}"]), "Transform") |> render_click()
      Process.sleep(100)
      html = render(view)

      assert html =~ "Failed"
      assert html =~ "Retry"
    end
  end

  # ═══════════════════════════════════════════════
  # Pure helpers
  # ═══════════════════════════════════════════════

  describe "etl_transformable?/1" do
    test "known suffixes" do
      assert Index.etl_transformable?("collision2017-2022.csv")
      assert Index.etl_transformable?("vehicle2017-2022.csv")
      assert Index.etl_transformable?("casualty2017-2022.csv")
      assert Index.etl_transformable?("vehicle-index.csv")
    end

    test "prefixed paths" do
      assert Index.etl_transformable?("uploads/2025/collision2017-2022.csv")
    end

    test "non-ETL files" do
      refute Index.etl_transformable?("random.csv")
      refute Index.etl_transformable?("notes.txt")
    end
  end

  describe "has_staging_table?/2" do
    test "true when exists" do
      assert Index.has_staging_table?(%{"f.csv" => "stg"}, "f.csv")
    end

    test "false when missing" do
      refute Index.has_staging_table?(%{}, "f.csv")
    end
  end

  describe "error_to_string/1" do
    test "known errors" do
      assert Index.error_to_string(:too_large) =~ "too large"
      assert Index.error_to_string(:not_accepted) =~ "CSV"
      assert Index.error_to_string(:too_many_files) =~ "5 files"
    end

    test "unknown errors" do
      assert Index.error_to_string(:weird) == ":weird"
    end
  end

  describe "format_size/1" do
    test "bytes",     do: assert Index.format_size(500) == "500 B"
    test "kilobytes", do: assert Index.format_size(2048) == "2.0 KB"
    test "megabytes", do: assert Index.format_size(5_242_880) == "5.0 MB"
  end
end