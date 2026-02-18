defmodule S3TestTask.RedshiftRepo do
  use Ecto.Repo,
    otp_app: :s3_test_task,
    adapter: Ecto.Adapters.Postgres
end
