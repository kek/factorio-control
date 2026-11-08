defmodule FactorioControl.Eyg.Evaluator do
  @moduledoc """
  Runs EYG programs through the native BEAM adapter of `eyg_json_bridge`.

  The bridge (`:eyg_json_bridge_beam`, built from Gleam source by mix_gleam) owns
  parsing, type checking against the JSON-shaped effect contracts, evaluation,
  argument and reply checking, the effect budget, payload limits and the
  evaluation processes: a guardian enforces the deadline and owner-death
  cleanup, and a heap-capped evaluator holds the continuation.

  This module is the Factorio side: it calls the effect handler under the run
  deadline, sends replies back, keeps the trace (in the event shape the earlier
  Node worker produced) and maps adapter outcomes to host results. Stopping
  evaluation never rolls back a game action.
  """

  @bridge :eyg_json_bridge_beam
  @max_timeout 300_000
  @default_heap_bytes 128 * 1024 * 1024
  @error_limit 4_000

  @doc """
  Run `code` with `contracts` (`%{"Effect" => %{"argument" => shape, "result" => shape}}`).

  `handler.(effect, argument)` returns `{:ok, value}`, `{:error, message}` (resumes
  the program with `Error(message)`) or `{:fatal, reason}` (stops evaluation).
  Returns `{:ok, result, trace}` for a finished evaluation, where `result["ok"]`
  says whether the program produced a value, or `{:error, reason, trace}` when the
  run stopped: `:run_timeout`, a handler's fatal reason, or `{:evaluator, text}`
  for an adapter failure such as a reply that does not match its contract.
  """
  def run(code, contracts, handler, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @max_timeout)
    max_effects = Keyword.get(opts, :max_effects, 100)
    heap_bytes = Keyword.get(opts, :max_heap_bytes, @default_heap_bytes)

    unless is_integer(timeout) and timeout in 1..@max_timeout and
             is_integer(max_effects) and max_effects in 1..100 do
      raise ArgumentError, "timeout must be 1..300000 ms; max_effects must be 1..100"
    end

    unless is_integer(heap_bytes) and heap_bytes in (1024 * 1024)..(512 * 1024 * 1024),
      do: raise(ArgumentError, "max_heap_bytes must be 1 MiB..512 MiB")

    bridge = Keyword.get(opts, :bridge, @bridge)
    inputs = encode!(Keyword.get(opts, :inputs, %{}), "inputs must be a JSON record")
    deadline = now() + timeout

    options = %{
      timeout_ms: timeout,
      max_effects: max_effects,
      max_heap_words: div(heap_bytes, :erlang.system_info(:wordsize))
    }

    case bridge.start(code, inputs, encode!(contracts, "invalid effect contracts"), options) do
      {:ok, run} ->
        monitor = Process.monitor(bridge.pid(run))

        state = %{
          bridge: bridge,
          run: run,
          monitor: monitor,
          handler: handler,
          deadline: deadline,
          trace: [],
          opts: opts
        }

        try do
          loop(state)
        after
          bridge.cancel(run)
          Process.demonitor(monitor, [:flush])
          flush(run)
        end

      {:error, reason} ->
        raise ArgumentError, "EYG run rejected: #{reason}"
    end
  end

  defp loop(%{run: run, monitor: monitor} = state) do
    receive do
      {:eyg_json_bridge, ^run, {:effect_request, id, effect, argument}} ->
        effect(state, id, effect, JSON.decode!(argument))

      {:eyg_json_bridge, ^run, {:result, {:ok, value}}} ->
        finish(state, %{"ok" => true, "value" => JSON.decode!(value)})

      {:eyg_json_bridge, ^run, {:result, {:error, reason}}} ->
        finish(state, %{"ok" => false, "error" => String.slice(reason, 0, 500)})

      {:eyg_json_bridge, ^run, {:error, reason}} ->
        # The bridge's deadline starts after ours, so expiry reaches here at or
        # after our own deadline; report it the same way as the local timer.
        if now() >= state.deadline,
          do: failure(:run_timeout, state),
          else: failure({:evaluator, reason}, state)

      {:DOWN, ^monitor, :process, _, reason} ->
        failure({:evaluator_exit, reason}, state)
    after
      max(state.deadline - now(), 0) -> failure(:run_timeout, state)
    end
  end

  defp effect(state, id, effect, argument) do
    request = %{
      "version" => 1,
      "type" => "effect-request",
      "id" => id,
      "effect" => effect,
      "argument" => argument
    }

    state = record(state, request)
    handler = state.handler

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
      case Task.yield(task, max(state.deadline - now(), 0)) do
        {:ok, value} ->
          value

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:fatal, :handler_timeout}
      end

    state = %{state | trace: drain_receipts(Keyword.get(state.opts, :receipt_ref), state.trace)}

    case outcome do
      {:ok, value} ->
        case json(value) do
          {:ok, encoded} ->
            reply(state, id, {:ok, encoded}, %{"ok" => true, "value" => JSON.decode!(encoded)})

          :error ->
            fatal(state, id, {:invalid_reply, "reply is not JSON-compatible"})
        end

      {:error, error} when is_binary(error) and byte_size(error) <= @error_limit ->
        reply(state, id, {:error, error}, %{"ok" => false, "error" => error})

      {:fatal, reason} ->
        fatal(state, id, reason)

      _ ->
        failure(:invalid_handler_reply, state)
    end
  end

  # The bridge validates the reply against the contract; a mismatch arrives as a
  # terminal adapter error, never as a catchable EYG Error.
  defp reply(state, id, message, body) do
    :ok = state.bridge.reply(state.run, id, message)
    response = Map.merge(body, %{"version" => 1, "type" => "effect-response", "id" => id})
    loop(record(state, response))
  end

  defp fatal(state, id, reason),
    do: failure(reason, record(state, %{type: "fatal", id: id, reason: inspect(reason)}))

  defp finish(state, body) do
    result = Map.merge(body, %{"version" => 1, "type" => "result"})
    state = record(state, result)
    {:ok, result, Enum.reverse(state.trace)}
  end

  defp failure(reason, state), do: {:error, reason, Enum.reverse(state.trace)}

  defp record(state, event) do
    if sink = Keyword.get(state.opts, :trace), do: sink.(event)
    %{state | trace: [event | state.trace]}
  end

  defp drain_receipts(ref, trace) do
    receive do
      {:eyg_receipt, ^ref, event} -> drain_receipts(ref, [event | trace])
    after
      0 -> trace
    end
  end

  # Late adapter messages for a finished run must not accumulate in the caller.
  defp flush(run) do
    receive do
      {:eyg_json_bridge, ^run, _} -> flush(run)
    after
      0 -> :ok
    end
  end

  defp json(value) do
    {:ok, JSON.encode!(value)}
  rescue
    _ -> :error
  end

  defp encode!(value, message) do
    JSON.encode!(value)
  rescue
    _ -> reraise ArgumentError, message, __STACKTRACE__
  end

  defp now, do: System.monotonic_time(:millisecond)
end
