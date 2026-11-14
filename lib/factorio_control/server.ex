defmodule FactorioControl.Server do
  @moduledoc """
  Owns the headless server through an Elixir Port. The default executable is
  scripts/server, which execs Factorio without an intermediate shell process.

  Output is streamed to subscribers and the last 64 KiB retained for inspection.
  Shutdown sends /quit on stdin and waits for an actual OS exit status. A timeout
  leaves the Port owned and inspectable rather than silently orphaning the game.
  Restart keeps this owner alive and relaunches the same configuration only after
  a clean OS exit. Stop cancels pending restart intent; failures never retry
  automatically. This is opt-in; starting the application or running tests never
  starts Factorio.
  """
  use GenServer, restart: :temporary
  require Logger
  @log_limit 65_536

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def status(server), do: GenServer.call(server, :status)
  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})
  def stop(server), do: GenServer.call(server, :stop, :infinity)

  @doc "Save and stop, then launch the same server again only after a clean OS exit."
  def restart(server), do: GenServer.call(server, :restart, :infinity)

  def await_ready(server, timeout \\ 10_000) do
    await_until(server, System.monotonic_time(:millisecond) + timeout)
  end

  @doc "Wait for a Port-owned one-shot process to exit; timeout leaves ownership intact."
  def await_exit(server, timeout \\ 30_000) when is_integer(timeout) and timeout >= 0 do
    await_exit_until(server, System.monotonic_time(:millisecond) + timeout)
  end

  defp await_exit_until(server, deadline) do
    case status(server) do
      %{state: :exited, exit_status: code} ->
        {:ok, code}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :exit_timeout}
        else
          Process.sleep(50)
          await_exit_until(server, deadline)
        end
    end
  end

  defp await_until(server, deadline) do
    case status(server) do
      %{state: :running} ->
        :ok

      %{state: :exited, exit_status: code} ->
        {:error, {:exit_status, code}}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :startup_timeout}
        else
          Process.sleep(50)
          await_until(server, deadline)
        end
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    root = opts |> Keyword.get(:directory, File.cwd!()) |> Path.expand()

    executable =
      opts |> Keyword.get(:executable, Path.join(root, "scripts/server")) |> Path.expand()

    password = Keyword.get(opts, :password) || System.get_env("FACTORIO_RCON_PASSWORD")

    if is_binary(password) and password != "" do
      state = %{
        launch: %{
          executable: executable,
          directory: root,
          args: Keyword.get(opts, :args, []),
          password: password
        },
        port: nil,
        os_pid: nil,
        state: :starting,
        exit_status: nil,
        output: "",
        subscribers: %{},
        waiters: [],
        restart_waiters: [],
        intent: nil,
        timer: nil,
        shutdown_tag: nil,
        shutdown_timeout: Keyword.get(opts, :shutdown_timeout, 10_000)
      }

      case launch(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:stop, :missing_password}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:os_pid, :state, :exit_status, :output]), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if state.output != "", do: send(pid, {:factorio, self(), {:output, state.output}})

    if state.state == :exited,
      do: send(pid, {:factorio, self(), {:exit_status, state.exit_status}})

    subscribers =
      if Map.has_key?(state.subscribers, pid),
        do: state.subscribers,
        else: Map.put(state.subscribers, pid, Process.monitor(pid))

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:stop, _from, %{state: :exited} = state),
    do: {:reply, :ok, %{state | intent: :quit}}

  def handle_call(:stop, from, state) do
    Enum.each(state.restart_waiters, &GenServer.reply(&1, {:error, :restart_cancelled}))
    state = request_shutdown(%{state | restart_waiters: [], intent: :quit})
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:restart, _from, %{state: :exited, exit_status: code} = state) when code != 0,
    do: {:reply, {:error, {:exit_status, code}}, state}

  # A delayed restart caller must not resurrect an owner explicitly quit by
  # the console or SIGTERM. Start a fresh owner after a completed explicit stop.
  def handle_call(:restart, _from, %{state: :exited, intent: :quit} = state),
    do: {:reply, {:error, :shutdown_requested}, state}

  def handle_call(:restart, _from, %{state: :exited} = state) do
    case launch(state) do
      {:ok, state} ->
        notify(state, {:restarted, state.os_pid})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:restart, _from, %{intent: :quit} = state),
    do: {:reply, {:error, :shutdown_in_progress}, state}

  def handle_call(:restart, from, state) do
    state = request_shutdown(%{state | intent: :restart})
    {:noreply, %{state | restart_waiters: [from | state.restart_waiters]}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    output = state.output <> data

    output =
      if byte_size(output) > @log_limit,
        do: binary_part(output, byte_size(output) - @log_limit, @log_limit),
        else: output

    ready = state.state == :starting and String.contains?(output, "Starting RCON interface")
    Enum.each(Map.keys(state.subscribers), &send(&1, {:factorio, self(), {:output, data}}))
    {:noreply, %{state | output: output, state: if(ready, do: :running, else: state.state)}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    Enum.each(
      state.waiters,
      &GenServer.reply(&1, if(code == 0, do: :ok, else: {:error, {:exit_status, code}}))
    )

    restart_waiters = state.restart_waiters
    restarting = state.intent == :restart and code == 0

    state = %{
      state
      | state: :exited,
        exit_status: code,
        port: nil,
        waiters: [],
        restart_waiters: [],
        timer: nil,
        shutdown_tag: nil,
        intent: if(state.intent == :quit, do: :quit, else: nil)
    }

    if restarting do
      case launch(state) do
        {:ok, state} ->
          notify(state, {:restarted, state.os_pid})
          Enum.each(restart_waiters, &GenServer.reply(&1, :ok))
          {:noreply, state}

        {:error, reason} ->
          Enum.each(restart_waiters, &GenServer.reply(&1, {:error, reason}))
          notify(state, {:restart_failed, reason})
          {:noreply, state}
      end
    else
      Enum.each(restart_waiters, &GenServer.reply(&1, {:error, {:exit_status, code}}))
      notify(state, {:exit_status, code})
      {:noreply, state}
    end
  end

  def handle_info({:shutdown_timeout, tag}, %{shutdown_tag: tag} = state) when not is_nil(tag) do
    Enum.each(
      state.waiters ++ state.restart_waiters,
      &GenServer.reply(&1, {:error, :shutdown_timeout})
    )

    {:noreply,
     %{state | waiters: [], restart_waiters: [], intent: nil, timer: nil, shutdown_tag: nil}}
  end

  def handle_info({:shutdown_timeout, _stale_tag}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    subscribers =
      if state.subscribers[pid] == ref,
        do: Map.delete(state.subscribers, pid),
        else: state.subscribers

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}
  def handle_info({:EXIT, _port, :normal}, state), do: {:noreply, state}

  # Normal supervision shutdown must also request a real process exit. A forced
  # BEAM/OS kill bypasses this callback; Ports alone do not guarantee OS reaping.
  @impl true
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, state) do
    if Port.info(state.port) do
      request_quit(state.port)
      wait_for_exit(state.port, System.monotonic_time(:millisecond) + state.shutdown_timeout)
    end
  end

  @impl true
  def format_status(status) do
    Map.update!(status, :state, fn state ->
      %{state | launch: :redacted}
    end)
  end

  defp request_shutdown(%{timer: timer} = state) when not is_nil(timer), do: state

  defp request_shutdown(state) do
    request_quit(state.port)
    tag = make_ref()

    %{
      state
      | state: :stopping,
        shutdown_tag: tag,
        timer: Process.send_after(self(), {:shutdown_timeout, tag}, state.shutdown_timeout)
    }
  end

  defp launch(state) do
    spec = state.launch

    try do
      port =
        Port.open({:spawn_executable, to_charlist(spec.executable)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:cd, to_charlist(spec.directory)},
          {:args, spec.args},
          {:env, [{~c"FACTORIO_RCON_PASSWORD", to_charlist(spec.password)}]}
        ])

      # A fast one-shot exit may already be queued when querying the pid.
      {:ok,
       %{
         state
         | port: port,
           os_pid: port_os_pid(port),
           state: :starting,
           exit_status: nil,
           output: "",
           intent: nil
       }}
    rescue
      _ in [ArgumentError, ErlangError] -> {:error, :could_not_start_server}
    end
  end

  defp notify(state, event) do
    Enum.each(Map.keys(state.subscribers), &send(&1, {:factorio, self(), event}))
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp request_quit(port) do
    Port.command(port, "/quit\n")
  rescue
    # The OS process may have exited just before its exit_status was handled.
    ArgumentError -> :ok
  end

  defp wait_for_exit(port, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> wait_for_exit(port, deadline)
      {:EXIT, ^port, _} -> wait_for_exit(port, deadline)
    after
      remaining -> Logger.error("Factorio did not exit before the shutdown deadline")
    end
  end
end
