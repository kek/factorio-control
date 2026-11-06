defmodule Mix.Tasks.Factorio do
  use Mix.Task
  @shortdoc "Call the local Factorio bot: mix factorio inspect '{\"radius\":16}'"
  def run(args) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(args, strict: [host: :string, port: :integer])
    if invalid != [], do: Mix.raise("Unknown options: #{inspect(invalid)}")

    {method, params} =
      case args do
        [method] -> {method, %{}}
        [method, json] -> {method, JSON.decode!(json)}
        _ -> Mix.raise("Usage: mix factorio [--host localhost] [--port 27015] METHOD [JSON_ARGS]")
      end

    password = System.get_env("FACTORIO_RCON_PASSWORD") || Mix.raise("Set FACTORIO_RCON_PASSWORD")

    case FactorioControl.Rcon.start_link(Keyword.put(opts, :password, password)) do
      {:ok, client} ->
        try do
          case FactorioControl.Bot.call(client, method, params) do
            {:ok, result} ->
              Mix.shell().info(JSON.encode!(result))
              if result["ok"] == false, do: Mix.raise("Bot rejected the request")

            {:error, reason} ->
              Mix.raise("RCON failed: #{inspect(reason)}")
          end
        after
          FactorioControl.Rcon.close(client)
        end

      {:error, reason} ->
        Mix.raise("Connection failed: #{inspect(reason)}")
    end
  end
end
