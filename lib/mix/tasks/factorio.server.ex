defmodule Mix.Tasks.Factorio.Server do
  use Mix.Task
  @shortdoc "Run the local Factorio server (q + Enter quits; r + Enter restarts)"

  def run([]) do
    Mix.Task.run("app.start")
    {:ok, server} = FactorioControl.Server.start_link()
    # SIGTERM performs the same orderly shutdown as Server.stop/1 from IEx.
    System.trap_signal(:sigterm, fn -> safe_stop(server) end)
    System.at_exit(fn _ -> safe_stop(server) end)

    case FactorioControl.ServerConsole.run(server) do
      :ok ->
        :ok

      {:error, {:exit_status, code}} ->
        Mix.raise("Factorio exited with status #{code}")

      {:error, reason} ->
        Mix.raise(
          "Server lifecycle failed: #{inspect(reason)}; inspect the native process before restarting"
        )
    end
  end

  def run(_), do: Mix.raise("Usage: mix factorio.server")

  defp safe_stop(server) do
    if Process.alive?(server), do: FactorioControl.Server.stop(server)
  catch
    :exit, _ -> :ok
  end
end
