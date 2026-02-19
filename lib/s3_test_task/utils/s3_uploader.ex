defmodule S3TestTask.Utils.S3Uploader do
  def bucket do
    Application.get_env(:s3_test_task, :s3_bucket) ||
      raise "S3_BUCKET not configured!"
  end

  def upload_file(file_path, filename) do
    content = File.read!(file_path)
    key = "uploads/#{Date.utc_today()}/#{Ecto.UUID.generate()}_#{filename}"

    case ExAws.S3.put_object(bucket(), key, content, content_type: "text/csv")
         |> ExAws.request() do
      {:ok, _} ->
        {:ok, %{key: key, url: get_url(key)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_files(prefix \\ "uploads/") do
    case ExAws.S3.list_objects(bucket(), prefix: prefix)
         |> ExAws.request() do
      {:ok, %{body: %{contents: contents}}} ->
        files =
          contents
          |> Enum.map(fn file ->
            %{
              key: file.key,
              name: Path.basename(file.key),
              size: parse_size(file.size),
              last_modified: file.last_modified,
              url: get_url(file.key)
            }
          end)
          |> Enum.reject(fn f -> String.ends_with?(f.key, "/") end)

        {:ok, files}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_url(key) do
    "https://#{bucket()}.s3.eu-central-1.amazonaws.com/#{key}"
  end

  defp parse_size(size) when is_binary(size), do: String.to_integer(size)
  defp parse_size(size) when is_integer(size), do: size
  defp parse_size(_), do: 0
end
