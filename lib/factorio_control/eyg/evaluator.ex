defmodule FactorioControl.Eyg.Evaluator do
  @moduledoc """
  Evaluates EYG programs inside this VM with host-owned effect contracts.

  Upstream `eyg_parser`, `eyg_analysis` and `eyg_interpreter` (compiled from Gleam
  by mix_gleam) parse, type-check and run the program. This module turns the
  JSON-shaped contracts into EYG types, validates every effect argument and host
  reply against them, and drives the interpreter's pause/resume loop.

  Each run gets its own process with a heap cap. The caller enforces the wall-clock
  deadline and kills that process on timeout, completion or caller death; a pure
  infinite loop cannot block the host. Killing evaluation never rolls back a game
  action. Trace events keep the shape the earlier Node worker produced.
  """

  @infer :eyg@analysis@inference@levels_j@contextual
  @types :eyg@analysis@type_@isomorphic
  @expression :eyg@interpreter@expression
  @parser :eyg@parser
  @debug :eyg@interpreter@simple_debug

  @safe 9_007_199_254_740_991
  @frame_limit 64_000
  @transfer_limit 8_000_000
  @result_limit 12_000
  @error_limit 4_000
  @default_heap_bytes 128 * 1024 * 1024
  @unit {:record, %{}}

  @doc """
  Run `code` with `contracts` (`%{"Effect" => %{"argument" => shape, "result" => shape}}`).

  `handler.(effect, argument)` returns `{:ok, value}`, `{:error, message}` (resumes
  the program with `Error(message)`) or `{:fatal, reason}` (stops evaluation).
  Returns `{:ok, result, trace}` for a finished evaluation, where `result["ok"]`
  says whether the program produced a value, or `{:error, reason, trace}` when the
  host stopped it.
  """
  def run(code, contracts, handler, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    max_effects = Keyword.get(opts, :max_effects, 100)

    unless is_integer(timeout) and timeout in 1..600_000 and
             is_integer(max_effects) and max_effects in 1..100 do
      raise ArgumentError, "timeout must be 1..600000 ms; max_effects must be 1..100"
    end

    heap_bytes = Keyword.get(opts, :max_heap_bytes, @default_heap_bytes)

    unless is_integer(heap_bytes) and heap_bytes in (1024 * 1024)..(1024 * 1024 * 1024),
      do: raise(ArgumentError, "max_heap_bytes must be 1 MiB..1 GiB")

    heap_words = div(heap_bytes, :erlang.system_info(:wordsize))
    shapes = contracts |> normalize() |> validate_contracts!()
    source = program(code, Keyword.get(opts, :inputs, %{}))
    context = context(shapes)
    owner = self()

    body =
      case Keyword.get(opts, :test_evaluator) do
        nil -> fn -> evaluate(owner, source, context) end
        scripted -> fn -> scripted.(owner) end
      end

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: heap_words, kill: true, error_logger: false})
        body.()
      end)

    # A caller crash must also stop evaluation stuck in pure computation.
    guard =
      spawn(fn ->
        owner_ref = Process.monitor(owner)

        receive do
          :finished -> Process.demonitor(owner_ref, [:flush])
          {:DOWN, ^owner_ref, _, _, _} -> Process.exit(pid, :kill)
        end
      end)

    state = %{
      pid: pid,
      ref: ref,
      handler: handler,
      shapes: shapes,
      deadline: now() + timeout,
      budget: max_effects,
      id: 1,
      trace: [],
      bytes_out: 0,
      bytes_in: 0,
      opts: opts
    }

    try do
      loop(state)
    after
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])
      send(guard, :finished)
    end
  end

  ## Evaluation process

  defp evaluate(owner, source, context) do
    case @parser.all_from_string(source) do
      {:error, reason} ->
        failed(owner, "parse: " <> @parser.format_error(reason, source))

      {:ok, ast} ->
        case @infer.check(context, ast) do
          {:lookup, _reference, _resume} ->
            failed(owner, "imports/references denied")

          {:done, analysis} ->
            case @infer.all_errors(analysis) do
              [] -> drive(owner, @expression.execute(ast, []))
              _ -> failed(owner, "type check failed (invalid type or unapproved effects)")
            end
        end
    end
  end

  defp drive(owner, {:ok, value}), do: send(owner, {self(), :done, value})

  defp drive(owner, {:error, {{:unhandled_effect, effect, argument}, _span, env, stack}}) do
    send(owner, {self(), :effect, effect, argument})

    receive do
      {:resume, reply} -> drive(owner, @expression.resume(reply, env, stack))
    end
  end

  defp drive(owner, {:error, {reason, _span, _env, _stack}}) do
    failed(owner, "EYG evaluation failed: " <> describe(reason))
  end

  defp failed(owner, message), do: send(owner, {self(), :failed, message})

  defp describe(reason) do
    @debug.describe(reason)
  rescue
    _ -> inspect(reason, limit: 20)
  end

  ## Host loop

  defp loop(%{pid: pid, ref: ref} = state) do
    remaining = max(state.deadline - now(), 0)

    receive do
      {^pid, :effect, effect, argument} ->
        effect(state, effect, argument)

      {^pid, :done, value} ->
        case encode(value, 0) do
          {:ok, json} -> finish(state, %{"ok" => true, "value" => json})
          {:error, message} -> finish(state, %{"ok" => false, "error" => message})
        end

      {^pid, :failed, message} ->
        finish(state, %{"ok" => false, "error" => String.slice(message, 0, 500)})

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        failure(:evaluator_memory_exceeded, state)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        failure({:evaluator_exit, reason}, state)
    after
      remaining -> failure(:run_timeout, state)
    end
  end

  defp effect(state, effect, argument) do
    with {:ok, shape} <- granted(state, effect),
         :ok <- budget(state),
         {:ok, json} <- argument(argument, shape["argument"]) do
      request = %{
        "version" => 1,
        "type" => "effect-request",
        "id" => state.id,
        "effect" => effect,
        "argument" => json
      }

      case add_bytes(state, :bytes_out, request) do
        {:ok, state} -> dispatch(record(state, request), effect, json, shape["result"])
        {:error, reason} -> failure(reason, state)
      end
    else
      {:result, message} -> finish(state, %{"ok" => false, "error" => message})
      {:fatal, reason} -> failure(reason, record(state, fatal_event(state, reason)))
    end
  end

  defp granted(state, effect) do
    case Map.fetch(state.shapes, effect) do
      {:ok, shape} -> {:ok, shape}
      :error -> {:fatal, :unapproved_effect}
    end
  end

  defp budget(%{budget: budget}) when budget > 0, do: :ok
  defp budget(_), do: {:result, "effect budget exceeded"}

  defp argument(value, shape) do
    case to_json(value, shape) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:result, "invalid typed effect argument"}
    end
  end

  defp dispatch(state, effect, argument, reply_shape) do
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
        with {:ok, json} <- normalize_reply(value),
             {:ok, eyg} <- from_json(json, reply_shape) do
          reply(state, %{"ok" => true, "value" => json}, {:tagged, "Ok", eyg})
        else
          {:error, message} ->
            reason = {:invalid_reply, message}
            failure(reason, record(state, fatal_event(state, reason)))
        end

      {:error, error} when is_binary(error) and byte_size(error) <= @error_limit ->
        reply(state, %{"ok" => false, "error" => error}, {:tagged, "Error", {:string, error}})

      {:fatal, reason} ->
        failure(reason, record(state, fatal_event(state, reason)))

      _ ->
        failure(:invalid_handler_reply, state)
    end
  end

  defp reply(state, body, eyg) do
    response = Map.merge(body, %{"version" => 1, "type" => "effect-response", "id" => state.id})

    case add_bytes(state, :bytes_in, response) do
      {:ok, state} ->
        state = record(state, response)
        send(state.pid, {:resume, eyg})
        loop(%{state | budget: state.budget - 1, id: state.id + 1})

      {:error, reason} ->
        failure(reason, state)
    end
  end

  defp finish(state, body) do
    result = Map.merge(body, %{"version" => 1, "type" => "result"})

    if byte_size(JSON.encode!(result)) <= @result_limit + 600 do
      state = record(state, result)
      {:ok, result, Enum.reverse(state.trace)}
    else
      failure(:result_too_large, state)
    end
  end

  defp fatal_event(state, reason), do: %{type: "fatal", id: state.id, reason: inspect(reason)}

  defp add_bytes(state, key, event) do
    size = byte_size(JSON.encode!(event))
    total = Map.fetch!(state, key) + size

    cond do
      size > @frame_limit -> {:error, :frame_too_large}
      total > @transfer_limit -> {:error, :transfer_budget_exceeded}
      true -> {:ok, Map.put(state, key, total)}
    end
  end

  defp drain_receipts(ref, trace) do
    receive do
      {:eyg_receipt, ^ref, event} -> drain_receipts(ref, [event | trace])
    after
      0 -> trace
    end
  end

  defp record(state, event) do
    if sink = Keyword.get(state.opts, :trace), do: sink.(event)
    %{state | trace: [event | state.trace]}
  end

  defp failure(reason, state), do: {:error, reason, Enum.reverse(state.trace)}
  defp now, do: System.monotonic_time(:millisecond)

  ## Contracts and types

  # Host contracts may use atom or string keys; compare them as JSON would.
  defp normalize(contracts), do: contracts |> JSON.encode!() |> JSON.decode!()

  defp validate_contracts!(contracts) do
    valid =
      is_map(contracts) and map_size(contracts) <= 32 and
        Enum.all?(contracts, fn {name, contract} ->
          name =~ ~r/\A[A-Z][A-Za-z0-9]*\z/ and is_map(contract) and
            Map.keys(contract) |> Enum.sort() == ["argument", "result"] and
            valid_shape?(contract["argument"], 0) and valid_shape?(contract["result"], 0)
        end)

    if valid, do: contracts, else: raise(ArgumentError, "invalid effect contracts")
  end

  defp valid_shape?(_, depth) when depth > 8, do: false

  defp valid_shape?(%{"kind" => kind} = shape, _) when kind in ["string", "integer", "boolean"],
    do: map_size(shape) == 1

  defp valid_shape?(%{"kind" => "list", "items" => items} = shape, depth),
    do: map_size(shape) == 2 and valid_shape?(items, depth + 1)

  defp valid_shape?(%{"kind" => "record", "fields" => fields} = shape, depth)
       when is_map(fields) do
    map_size(shape) == 2 and map_size(fields) <= 64 and
      Enum.all?(fields, fn {name, field} ->
        name =~ ~r/\A[a-z_][a-z0-9_]*\z/ and valid_shape?(field, depth + 1)
      end)
  end

  defp valid_shape?(_, _), do: false

  defp context(shapes) do
    Enum.reduce(shapes, @infer.pure(), fn {name, contract}, context ->
      @infer.with_effect(
        context,
        name,
        type(contract["argument"]),
        @types.result(type(contract["result"]), :string)
      )
    end)
  end

  defp type(%{"kind" => "string"}), do: :string
  defp type(%{"kind" => "integer"}), do: :integer

  defp type(%{"kind" => "boolean"}),
    do: @types.union([{"True", unit_type()}, {"False", unit_type()}])

  defp type(%{"kind" => "list", "items" => items}), do: {:list, type(items)}

  defp type(%{"kind" => "record", "fields" => fields}),
    do: @types.record(Enum.map(Enum.sort(fields), fn {name, shape} -> {name, type(shape)} end))

  defp unit_type, do: @types.record([])

  ## Values

  defp to_json({:string, text}, %{"kind" => "string"}), do: {:ok, text}
  defp to_json({:integer, n}, %{"kind" => "integer"}) when abs(n) <= @safe, do: {:ok, n}
  defp to_json({:tagged, "True", @unit}, %{"kind" => "boolean"}), do: {:ok, true}
  defp to_json({:tagged, "False", @unit}, %{"kind" => "boolean"}), do: {:ok, false}

  defp to_json({:linked_list, items}, %{"kind" => "list", "items" => shape}),
    do: map_all(items, &to_json(&1, shape))

  defp to_json({:record, fields}, %{"kind" => "record", "fields" => shapes}) do
    if Enum.sort(Map.keys(fields)) == Enum.sort(Map.keys(shapes)) do
      fields
      |> Enum.to_list()
      |> map_all(fn {name, value} ->
        with {:ok, json} <- to_json(value, shapes[name]), do: {:ok, {name, json}}
      end)
      |> then(fn result -> with {:ok, pairs} <- result, do: {:ok, Map.new(pairs)} end)
    else
      {:error, "Expected exact record"}
    end
  end

  defp to_json(_, _), do: {:error, "argument does not match contract"}

  defp normalize_reply(value) do
    {:ok, value |> JSON.encode!() |> JSON.decode!()}
  rescue
    _ -> {:error, "reply is not JSON-compatible"}
  end

  defp from_json(text, %{"kind" => "string"}) when is_binary(text), do: {:ok, {:string, text}}

  defp from_json(n, %{"kind" => "integer"}) when is_integer(n) and abs(n) <= @safe,
    do: {:ok, {:integer, n}}

  defp from_json(true, %{"kind" => "boolean"}), do: {:ok, {:tagged, "True", @unit}}
  defp from_json(false, %{"kind" => "boolean"}), do: {:ok, {:tagged, "False", @unit}}

  defp from_json(items, %{"kind" => "list", "items" => shape}) when is_list(items) do
    with {:ok, values} <- map_all(items, &from_json(&1, shape)), do: {:ok, {:linked_list, values}}
  end

  defp from_json(fields, %{"kind" => "record", "fields" => shapes}) when is_map(fields) do
    if Enum.sort(Map.keys(fields)) == Enum.sort(Map.keys(shapes)) do
      fields
      |> Enum.to_list()
      |> map_all(fn {name, json} ->
        with {:ok, value} <- from_json(json, shapes[name]), do: {:ok, {name, value}}
      end)
      |> then(fn result -> with {:ok, pairs} <- result, do: {:ok, {:record, Map.new(pairs)}} end)
    else
      {:error, "Expected exact record"}
    end
  end

  defp from_json(_, %{"kind" => kind}), do: {:error, "Expected #{kind}"}

  # Final results are untyped: allow any JSON-compatible EYG value.
  defp encode(_, depth) when depth > 64, do: {:error, "result too deeply nested"}

  defp encode({:integer, n}, _) when abs(n) <= @safe, do: {:ok, n}

  defp encode({:integer, _}, _),
    do: {:error, "result integer exceeds JavaScript safe range"}

  defp encode({:string, text}, _), do: {:ok, text}
  defp encode({:tagged, "True", _}, _), do: {:ok, true}
  defp encode({:tagged, "False", _}, _), do: {:ok, false}
  defp encode({:linked_list, items}, depth), do: map_all(items, &encode(&1, depth + 1))

  defp encode({:record, fields}, depth) do
    fields
    |> Enum.to_list()
    |> map_all(fn {name, value} ->
      with {:ok, json} <- encode(value, depth + 1), do: {:ok, {name, json}}
    end)
    |> then(fn result -> with {:ok, pairs} <- result, do: {:ok, Map.new(pairs)} end)
  end

  defp encode(_, _), do: {:error, "result is not JSON-compatible"}

  defp map_all(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  ## Program inputs

  @identifier ~r/\A[a-z_][a-z0-9_]*\z/

  @doc "Prefix `code` with `let input = …`, encoding inputs as an EYG literal."
  def program(code, inputs \\ %{}) do
    unless is_binary(code) and String.trim(code) != "" and String.length(code) <= 64_000,
      do: raise(ArgumentError, "Provide EYG source (max 64K characters)")

    unless is_map(inputs), do: raise(ArgumentError, "inputs must be a record")

    encoded =
      try do
        JSON.encode!(inputs)
      rescue
        _ -> raise ArgumentError, "inputs must be JSON"
      end

    if byte_size(encoded) > 500_000, do: raise(ArgumentError, "Inputs exceed 500 KB")
    source = "let input = #{literal(JSON.decode!(encoded), 0)}\n#{code}"
    if byte_size(source) > 1_000_000, do: raise(ArgumentError, "Source and inputs exceed 1 MiB")
    source
  end

  defp literal(_, depth) when depth > 32,
    do: raise(ArgumentError, "Input exceeds 32 nesting levels")

  defp literal(text, _) when is_binary(text), do: JSON.encode!(text)
  defp literal(n, _) when is_integer(n) and abs(n) <= @safe, do: Integer.to_string(n)
  defp literal(true, _), do: "True({})"
  defp literal(false, _), do: "False({})"

  defp literal(items, depth) when is_list(items),
    do: "[" <> Enum.map_join(items, ", ", &literal(&1, depth + 1)) <> "]"

  defp literal(fields, depth) when is_map(fields) do
    "{" <>
      Enum.map_join(Enum.sort(fields), ", ", fn {key, value} ->
        unless key =~ @identifier,
          do: raise(ArgumentError, "Unsupported input field: #{String.slice(key, 0, 60)}")

        "#{key}: #{literal(value, depth + 1)}"
      end) <> "}"
  end

  defp literal(_, _),
    do:
      raise(
        ArgumentError,
        "Inputs must contain only safe integers, strings, booleans, arrays or records (no null/floats)"
      )
end
