defmodule Mix.Tasks.Factorio.Server do
  use Mix.Task
  @shortdoc "Run the local Factorio server in an Elixir Port"

  def run([]) do
    Mix.Task.run("app.start")
    {:ok, server} = FactorioControl.Server.start_link()
    FactorioControl.Server.subscribe(server)
    # SIGTERM performs the same orderly shutdown as Server.stop/1 from IEx.
    System.trap_signal(:sigterm, fn -> safe_stop(server) end)
    System.at_exit(fn _ -> safe_stop(server) end)
    stream(server)
  end

  def run(_), do: Mix.raise("Usage: mix factorio.server")

  defp safe_stop(server) do
    if Process.alive?(server), do: FactorioControl.Server.stop(server)
  catch
    :exit, _ -> :ok
  end

  defp stream(server) do
    receive do
      {:factorio, ^server, {:output, data}} ->
        IO.binwrite(data)
        stream(server)

      {:factorio, ^server, {:exit_status, 0}} ->
        :ok

      {:factorio, ^server, {:exit_status, code}} ->
        Mix.raise("Factorio exited with status #{code}")
    end
  end
end
