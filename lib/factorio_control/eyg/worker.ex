defmodule FactorioControl.Eyg.Worker do
  @moduledoc "Bounded host for the shared EYG NDJSON worker; never forwards raw Lua."
  @frame_limit 64_000

  def run(code, contracts, handler, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    max_effects = Keyword.get(opts, :max_effects, 100)
    worker = Keyword.fetch!(opts, :worker)
    node = System.find_executable("node") || raise "Node is required"

    unless is_integer(timeout) and timeout in 1..600_000 and
             is_integer(max_effects) and max_effects in 1..100 do
      raise ArgumentError, "timeout must be 1..600000 ms; max_effects must be 1..100"
    end

    start =
      JSON.encode!(%{
        version: 1,
        type: "start",
        code: code,
        inputs: Keyword.get(opts, :inputs, %{}),
        contracts: contracts,
        max_effects: max_effects
      })

    if byte_size(start) > 1_000_000, do: raise(ArgumentError, "start frame exceeds 1 MB")

    environment =
      Enum.map(Map.delete(System.get_env(), "NODE_ENV"), fn {name, _} ->
        {String.to_charlist(name), false}
      end)

    environment = [{~c"NODE_ENV", ~c"production"} | environment]

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:env, environment},
        {:line, @frame_limit},
        {:args, ["--max-old-space-size=128", worker]}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    owner = self()
    # A caller crash must also terminate a worker stuck in pure computation.
    guard =
      spawn(fn ->
        ref = Process.monitor(owner)

        receive do
          :finished -> Process.demonitor(ref, [:flush])
          {:DOWN, ^ref, _, _, _} -> kill(pid)
        end
      end)

    try do
      Port.command(port, start <> "\n")
      loop(port, handler, now() + timeout, max_effects, 1, [], "", 0, nil, opts)
    after
      if Port.info(port) do
        kill(pid)
        Port.close(port)
      end

      send(guard, :finished)
    end
  end

  defp loop(port, handler, deadline, budget, id, trace, partial, bytes, result, opts) do
    remaining = max(deadline - now(), 0)

    if remaining == 0 do
      failure(:run_timeout, trace)
    else
      receive do
        {^port, {:data, {tag, chunk}}} ->
          bytes = bytes + byte_size(chunk)
          line = partial <> chunk

          cond do
            byte_size(line) > @frame_limit or bytes > 8_000_000 ->
              failure(:output_budget_exceeded, trace)

            tag == :noeol ->
              loop(port, handler, deadline, budget, id, trace, line, bytes, result, opts)

            result != nil ->
              failure(:output_after_result, trace)

            true ->
              case JSON.decode(line) do
                {:ok, %{"version" => 1} = frame} ->
                  dispatch(frame, port, handler, deadline, budget, id, trace, bytes, opts)

                _ ->
                  failure(:invalid_worker_frame, trace)
              end
          end

        {^port, {:exit_status, 0}} when result != nil and partial == "" ->
          {:ok, result, Enum.reverse(trace)}

        {^port, {:exit_status, status}} ->
          failure({:worker_exit, status}, trace)
      after
        remaining -> failure(:run_timeout, trace)
      end
    end
  end

  defp dispatch(
         %{"type" => "effect-request", "id" => id, "effect" => effect, "argument" => argument} =
           request,
         port,
         handler,
         deadline,
         budget,
         id,
         trace,
         bytes,
         opts
       )
       when budget > 0 do
    trace = record(request, trace, opts)

    task =
      Task.async(fn ->
        try do
          handler.(effect, argument)
        rescue
          error -> {:fatal, {:handler_exception, Exception.message(error)}}
        catch
          kind, reason -> {:fatal, {:handler_exit, kind, reason}}
        end
      end)

    outcome =
      case Task.yield(task, max(deadline - now(), 0)) do
        {:ok, value} ->
          value

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:fatal, :handler_timeout}
      end

    trace = drain_receipts(Keyword.get(opts, :receipt_ref), trace)

    case outcome do
      {:ok, value} ->
        reply(
          port,
          handler,
          deadline,
          budget,
          id,
          trace,
          bytes,
          %{"ok" => true, "value" => value},
          opts
        )

      {:error, error} when is_binary(error) and byte_size(error) <= 4000 ->
        reply(
          port,
          handler,
          deadline,
          budget,
          id,
          trace,
          bytes,
          %{"ok" => false, "error" => error},
          opts
        )

      {:fatal, reason} ->
        failure(reason, record(%{type: "fatal", id: id, reason: inspect(reason)}, trace, opts))

      _ ->
        failure(:invalid_handler_reply, trace)
    end
  end

  defp dispatch(
         %{"type" => "result", "ok" => ok} = result,
         port,
         handler,
         deadline,
         budget,
         id,
         trace,
         bytes,
         opts
       )
       when is_boolean(ok) do
    valid = if ok, do: Map.has_key?(result, "value"), else: is_binary(result["error"])

    if valid and byte_size(JSON.encode!(result)) <= 12_600 do
      loop(
        port,
        handler,
        deadline,
        budget,
        id,
        record(result, trace, opts),
        "",
        bytes,
        result,
        opts
      )
    else
      failure(:invalid_result, trace)
    end
  end

  defp dispatch(frame, _, _, _, _, _, trace, _, _), do: failure({:worker_protocol, frame}, trace)

  defp reply(port, handler, deadline, budget, id, trace, bytes, value, opts) do
    response = Map.merge(value, %{"version" => 1, "type" => "effect-response", "id" => id})
    encoded = JSON.encode!(response)

    if byte_size(encoded) > @frame_limit do
      failure(:reply_budget_exceeded, trace)
    else
      trace = record(response, trace, opts)
      Port.command(port, encoded <> "\n")
      loop(port, handler, deadline, budget - 1, id + 1, trace, "", bytes, nil, opts)
    end
  end

  defp drain_receipts(ref, trace) do
    receive do
      {:eyg_receipt, ^ref, event} -> drain_receipts(ref, [event | trace])
    after
      0 -> trace
    end
  end

  defp record(event, trace, opts) do
    if sink = Keyword.get(opts, :trace), do: sink.(event)
    [event | trace]
  end

  defp failure(reason, trace), do: {:error, reason, Enum.reverse(trace)}
  defp now, do: System.monotonic_time(:millisecond)

  defp kill(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
