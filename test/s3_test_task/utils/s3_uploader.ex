defmodule S3TestTask.Utils.S3UploaderTest do
  use ExUnit.Case, async: false
  use Mimic

  alias S3TestTask.Utils.S3Uploader

  setup :verify_on_exit!

  # ═══════════════════════════════════════════════
  # bucket/0
  # ═══════════════════════════════════════════════

  describe "bucket/0" do
    test "returns configured bucket" do
      assert is_binary(S3Uploader.bucket())
    end
  end

  # ═══════════════════════════════════════════════
  # upload_file/2
  # ═══════════════════════════════════════════════

  describe "upload_file/2" do
    setup do
      path = Path.join(System.tmp_dir!(), "test_upload_#{:rand.uniform(100_000)}.csv")
      File.write!(path, "id,name\n1,Alice\n2,Bob\n")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "uploads file and returns key + url", %{path: path} do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:ok, %{status_code: 200}}
      end)

      assert {:ok, %{key: key, url: url}} = S3Uploader.upload_file(path, "data.csv")

      assert key =~ "uploads/"
      assert key =~ "_data.csv"
      assert key =~ Date.utc_today() |> to_string()
      assert url =~ S3Uploader.bucket()
      assert url =~ key
    end

    test "returns error on S3 failure", %{path: path} do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:error, {:http_error, 403, "Forbidden"}}
      end)

      assert {:error, {:http_error, 403, "Forbidden"}} =
               S3Uploader.upload_file(path, "data.csv")
    end

    test "generates unique keys for same filename", %{path: path} do
      expect(ExAws, :request, 2, fn %ExAws.Operation.S3{} ->
        {:ok, %{status_code: 200}}
      end)

      {:ok, %{key: key1}} = S3Uploader.upload_file(path, "same.csv")
      {:ok, %{key: key2}} = S3Uploader.upload_file(path, "same.csv")

      assert key1 != key2
    end
  end

  # ═══════════════════════════════════════════════
  # list_files/0 and list_files/1
  # ═══════════════════════════════════════════════

  describe "list_files/1" do
    test "returns parsed file list" do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:ok,
          %{
            body: %{
              contents: [
                %{key: "uploads/2025-01-01/abc_data.csv", size: "1024", last_modified: "2025-01-01T12:00:00Z"},
                %{key: "uploads/2025-01-01/def_report.csv", size: "2048", last_modified: "2025-01-01T13:00:00Z"}
              ]
            }
          }}
      end)

      assert {:ok, files} = S3Uploader.list_files()

      assert length(files) == 2

      first = Enum.at(files, 0)
      assert first.key == "uploads/2025-01-01/abc_data.csv"
      assert first.name == "abc_data.csv"
      assert first.size == 1024
      assert first.url =~ "abc_data.csv"
    end

    test "filters out directory entries" do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:ok,
          %{
            body: %{
              contents: [
                %{key: "uploads/", size: "0", last_modified: "2025-01-01T00:00:00Z"},
                %{key: "uploads/2025-01-01/", size: "0", last_modified: "2025-01-01T00:00:00Z"},
                %{key: "uploads/2025-01-01/file.csv", size: "500", last_modified: "2025-01-01T12:00:00Z"}
              ]
            }
          }}
      end)

      assert {:ok, files} = S3Uploader.list_files()
      assert length(files) == 1
      assert hd(files).name == "file.csv"
    end

    test "handles integer sizes" do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:ok,
          %{
            body: %{
              contents: [
                %{key: "uploads/file.csv", size: 4096, last_modified: "2025-01-01T12:00:00Z"}
              ]
            }
          }}
      end)

      assert {:ok, [file]} = S3Uploader.list_files()
      assert file.size == 4096
    end

    test "returns empty list when no files" do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:ok, %{body: %{contents: []}}}
      end)

      assert {:ok, []} = S3Uploader.list_files()
    end

    test "passes custom prefix" do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:ok, %{body: %{contents: []}}}
      end)

      assert {:ok, []} = S3Uploader.list_files("archive/")
    end

    test "returns error on S3 failure" do
      expect(ExAws, :request, fn %ExAws.Operation.S3{} ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = S3Uploader.list_files()
    end
  end
end