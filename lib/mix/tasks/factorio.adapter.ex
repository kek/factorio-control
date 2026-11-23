defmodule Mix.Tasks.Factorio.Adapter do
  use Mix.Task
  @shortdoc "Run one JSON-encoded EYG request from stdin (operator-configured)"

  def run(args) do
    Mix.Task.run("app.start", ["--no-compile"])

    result =
      if args == [] do
        input = IO.binread(:stdio, 64_001)

        with true <- is_binary(input) and byte_size(input) <= 64_000,
             {:ok, request} <- JSON.decode(input),
             {port, ""} <- Integer.parse(System.get_env("FACTORIO_RCON_PORT", "27015")) do
          FactorioControl.Eyg.Adapter.execute(request, %{
            host: System.get_env("FACTORIO_RCON_HOST", "localhost"),
            port: port,
            password: System.get_env("FACTORIO_RCON_PASSWORD", ""),
            bot: System.get_env("FACTORIO_BOT", "default"),
            memory_root: System.get_env("FACTORIO_EYG_MEMORY_ROOT"),
            allow_respawn: System.get_env("FACTORIO_EYG_ALLOW_RESPAWN") == "true",
            artifact_root: System.get_env("FACTORIO_EYG_ARTIFACT_ROOT", "tmp/factorio-eyg")
          })
        else
          _ -> rejected("Invalid JSON request or operator port; stdin limit is 64000 bytes")
        end
      else
        rejected("Adapter accepts no command-line arguments")
      end

    IO.puts(JSON.encode!(result))
  rescue
    _ ->
      IO.puts(
        JSON.encode!(%{
          success: false,
          error: "Adapter failed; inspect artifacts and world before retrying",
          value: nil,
          artifact_dir: nil,
          recovery_required: true
        })
      )
  end

  defp rejected(error),
    do: %{success: false, error: error, value: nil, artifact_dir: nil, recovery_required: false}
end
