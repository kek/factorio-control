defmodule FactorioControl.ServerConsole do
  @moduledoc "Line-buffered console for mix factorio.server; q/quit requests owned shutdown."
  alias FactorioControl.Server

  @help "Type q then Enter to save and quit gracefully."

  def run(server, opts \\ []) do
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stdio)
    :ok = Server.subscribe(server)
    IO.puts(output, @help)
    parent = self()
    token = make_ref()
    {reader, monitor} = spawn_monitor(fn -> read_lines(parent, token, input) end)
    owner_monitor = Process.monitor(server)

    try do
      stream(server, %{
        token: token,
        reader: monitor,
        owner: owner_monitor,
        stop: nil,
        output: output
      })
    after
      cancel(reader, monitor)
      Process.demonitor(owner_monitor, [:flush])
    end
  end

  defp read_lines(parent, token, input) do
    case IO.gets(input, "") do
      line when is_binary(line) ->
        send(parent, {:server_console_input, token, line})
        read_lines(parent, token, input)

      :eof ->
        :ok

      {:error, reason} ->
        send(parent, {:server_console_input_error, token, reason})
    end
  end

  defp stream(server, state) do
    receive do
      {:factorio, ^server, {:output, data}} ->
        IO.binwrite(state.output, data)
        stream(server, state)

      {:factorio, ^server, {:exit_status, code}} ->
        if state.stop, do: cancel(state.stop.pid, state.stop.monitor)
        if code == 0, do: :ok, else: {:error, {:exit_status, code}}

      {:server_console_input, token, line} when token == state.token ->
        command = String.trim(line)

        cond do
          command in ["q", "quit", "Q", "QUIT"] and is_nil(state.stop) ->
            IO.puts(state.output, "Saving and stopping Factorio; waiting for process exit...")
            stream(server, %{state | stop: start_stop(server)})

          command in ["q", "quit", "Q", "QUIT", ""] ->
            stream(server, state)

          true ->
            IO.puts(state.output, @help <> " Other input is not sent to the game.")
            stream(server, state)
        end

      {:server_console_input_error, token, reason} when token == state.token ->
        IO.puts(
          state.output,
          "Keyboard input unavailable (#{inspect(reason)}); SIGTERM can still request shutdown."
        )

        stream(server, state)

      {:server_console_stop_result, tag, result} ->
        case state.stop do
          %{tag: ^tag, monitor: monitor} ->
            Process.demonitor(monitor, [:flush])

            if result != :ok do
              IO.puts(
                state.output,
                "Shutdown not confirmed: #{inspect(result)}. Still waiting for Factorio; q then Enter retries explicitly."
              )
            end

            # A successful stop result is not a replacement for the subscribed
            # OS exit event. Continue streaming until that event arrives.
            stream(server, %{state | stop: nil})

          _ ->
            stream(server, state)
        end

      {:DOWN, monitor, :process, _pid, reason} ->
        cond do
          monitor == state.owner ->
            if state.stop, do: cancel(state.stop.pid, state.stop.monitor)
            {:error, {:owner_exit, reason}}

          monitor == state.reader ->
            if reason != :normal do
              IO.puts(
                state.output,
                "Keyboard reader exited (#{inspect(reason)}); SIGTERM can still request shutdown."
              )
            end

            stream(server, %{state | reader: nil})

          state.stop && monitor == state.stop.monitor ->
            IO.puts(
              state.output,
              "Shutdown worker exited (#{inspect(reason)}); shutdown remains unconfirmed."
            )

            stream(server, %{state | stop: nil})

          true ->
            stream(server, state)
        end
    end
  end

  defp start_stop(server) do
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            Server.stop(server)
          catch
            :exit, reason -> {:error, {:owner_exit, reason}}
          end

        send(parent, {:server_console_stop_result, tag, result})
      end)

    %{pid: pid, monitor: monitor, tag: tag}
  end

  defp cancel(pid, monitor) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])
  end
end
