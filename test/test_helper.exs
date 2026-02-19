
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(S3TestTask.RedshiftRepo, :manual)

# Mox mocks — определяем ЗДЕСЬ, а не в test/support/
Mimic.copy(S3TestTask.Utils.S3Uploader)
Mimic.copy(S3TestTask.Utils.RedshiftLoader)
Mimic.copy(S3TestTask.Utils.Transformer)
Mimic.copy(S3TestTask.Utils.EtlLog)
Mimic.copy(S3TestTask.RedshiftRepo)
Mimic.copy(ExAws)

