defmodule FactorioControl.Eyg do
  @moduledoc "Typed EYG gameplay effects backed by the existing Bot API."
  alias FactorioControl.{Bot, Eyg.Worker}

  defp scalar(kind), do: %{"kind" => kind}
  defp record(fields), do: %{"kind" => "record", "fields" => Map.new(fields)}
  defp list(item), do: %{"kind" => "list", "items" => item}
  defp contract(argument, result), do: %{"argument" => argument, "result" => result}

  def contracts do
    int = scalar("integer")
    text = scalar("string")
    position = record(x2: int, y2: int)
    stack = record(name: text, quality: text, count: int)
    resource = record(name: text, x_milli: int, y_milli: int, amount: int)
    entity = record(name: text, x_milli: int, y_milli: int, amount: int, output: list(stack))

    action =
      record(
        id: int,
        kind: text,
        status: text,
        count: int,
        started_tick: int,
        deadline_tick: int,
        finished_tick: int,
        has_position: scalar("boolean"),
        x_milli: int,
        y_milli: int,
        error_code: text,
        error_message: text
      )

    receipt = record(tick: int, count: int, action_id: int)

    %{
      "Inspect" =>
        contract(
          record(radius: int),
          record(
            tick: int,
            inventory: list(stack),
            entities: list(entity),
            truncated: scalar("boolean")
          )
        ),
      "InspectBot" =>
        contract(
          record([]),
          record(
            tick: int,
            bot:
              record(
                x_milli: int,
                y_milli: int,
                health_milli: int,
                surface: text,
                inventory: list(stack),
                active_actions: list(action)
              )
          )
        ),
      "InspectEntity" =>
        contract(
          record(name: text, position: position),
          record(
            tick: int,
            entity:
              record(
                name: text,
                type: text,
                unit_number: int,
                x_milli: int,
                y_milli: int,
                amount: int,
                status: text,
                inventory: list(stack),
                fuel: list(stack),
                input: list(stack),
                output: list(stack)
              )
          )
        ),
      "InspectResources" =>
        contract(
          record(item: text, radius: int),
          record(
            tick: int,
            resources: list(resource),
            truncated: scalar("boolean")
          )
        ),
      "InspectAction" => contract(record(id: int), record(tick: int, action: action)),
      "InspectSimulation" =>
        contract(
          record([]),
          record(
            tick: int,
            speed_milli: int,
            tick_paused: scalar("boolean"),
            connected_players: int,
            version: text
          )
        ),
      "WalkTo" => contract(record(position: position, timeout_ticks: int), receipt),
      "Mine" =>
        contract(record(position: position, item: text, count: int, timeout_ticks: int), receipt),
      "Build" => contract(record(position: position, item: text, direction: text), receipt),
      "Transfer" =>
        contract(
          record(
            position: position,
            entity: text,
            inventory: text,
            direction: text,
            item: text,
            count: int
          ),
          receipt
        ),
      "Wait" => contract(record(ticks: int), receipt),
      "Stop" => contract(record([]), receipt)
    }
  end

  def run(client, code, opts \\ []) do
    raw_call = Keyword.get(opts, :call, fn method, args -> Bot.call(client, method, args) end)
    raw_await = Keyword.get(opts, :await, fn id -> Bot.await(client, id) end)
    owner = self()
    receipt_ref = make_ref()

    emit = fn event ->
      send(owner, {:eyg_receipt, receipt_ref, event})
      if sink = Keyword.get(opts, :trace), do: sink.(event)
    end

    call = fn method, args ->
      # Record the attempt before calling the game: a handler can time out while
      # the request is in flight, before an acceptance receipt is available.
      if method in [:walk_to, :mine],
        do: emit.(%{type: "action_submission", method: to_string(method)})

      result = raw_call.(method, args)

      if method != :inspect,
        do:
          emit.(%{
            type: "game_receipt",
            method: to_string(method),
            result: receipt_result(result)
          })

      result
    end

    await = fn id ->
      result = raw_await.(id)
      emit.(%{type: "action_receipt", action_id: id, result: receipt_result(result)})
      result
    end

    opts = Keyword.put(opts, :receipt_ref, receipt_ref)
    allowed = Keyword.get(opts, :effects, Map.keys(contracts()))

    unless Enum.all?(allowed, &Map.has_key?(contracts(), &1)),
      do: raise(ArgumentError, "unknown effect grant")

    context = Map.take(contracts(), allowed)

    result =
      Worker.run(
        code,
        context,
        fn effect, argument ->
          if Map.has_key?(context, effect),
            do: handle(effect, argument, call, await),
            else: {:fatal, :unapproved_effect}
        end,
        opts
      )

    # Only host-side submissions can trigger cancellation. Worker requests alone
    # are not evidence that a permitted action reached the game.
    case result do
      {:error, _, trace} ->
        if unfinished_action?(trace) do
          cleanup =
            try do
              raw_call.(:stop, %{})
            catch
              kind, reason -> {kind, reason}
            end

          append_cleanup(result, cleanup, opts)
        else
          result
        end

      _ ->
        result
    end
  end

  defp unfinished_action?(trace) do
    Enum.reduce(trace, nil, fn
      %{type: "action_submission"}, _ ->
        :unconfirmed

      %{type: "game_receipt", method: method, result: %{response: %{"ok" => false}}}, pending
      when method in ["walk_to", "mine"] and not is_nil(pending) ->
        nil

      %{
        type: "game_receipt",
        method: method,
        result: %{response: %{"ok" => true, "data" => %{"id" => id}}}
      },
      pending
      when method in ["walk_to", "mine"] and not is_nil(pending) ->
        {:accepted, id}

      %{
        type: "action_receipt",
        action_id: id,
        result: %{response: %{"ok" => true, "data" => %{"id" => id, "status" => status}}}
      },
      {:accepted, id}
      when status in ["completed", "failed", "cancelled"] ->
        nil

      _, pending ->
        pending
    end) != nil
  end

  defp append_cleanup({tag, result, trace}, cleanup, opts) do
    event = %{type: "cleanup_stop", result: receipt_result(cleanup)}
    if sink = Keyword.get(opts, :trace), do: sink.(event)
    {tag, result, trace ++ [event]}
  end

  def handle("Inspect", %{"radius" => radius}, call, _)
      when is_integer(radius) and radius in 0..64 do
    with {:ok, response} <- invoke(call, :inspect, %{"radius" => radius}) do
      data = response["data"]

      entities =
        collection(data["entities"])
        |> Enum.map(fn entity ->
          %{
            "name" => entity["name"],
            "x_milli" => round(entity["position"]["x"] * 1000),
            "y_milli" => round(entity["position"]["y"] * 1000),
            "amount" => entity["amount"] || 0,
            "output" => stacks(entity["output"])
          }
        end)

      {:ok,
       %{
         "tick" => response["tick"],
         "inventory" => stacks(data["inventory"]),
         "entities" => entities,
         "truncated" => data["truncated"] == true
       }}
    end
  end

  def handle("InspectBot", args, call, _) when args == %{} do
    with {:ok, response} <- invoke(call, :inspect, %{"radius" => 0}) do
      data = response["data"]

      active =
        case data["active_action"] do
          nil -> []
          action -> [action_summary(action)]
        end

      {:ok,
       %{
         "tick" => response["tick"],
         "bot" => %{
           "x_milli" => milli(data["position"]["x"]),
           "y_milli" => milli(data["position"]["y"]),
           "health_milli" => milli(data["health"]),
           "surface" => data["surface"],
           "inventory" => stacks(data["inventory"]),
           "active_actions" => active
         }
       }}
    end
  end

  def handle("InspectEntity", %{"name" => name, "position" => pos}, call, _) do
    with :ok <- item(name),
         {:ok, position} <- position(pos),
         {:ok, response} <-
           invoke(call, :inspect_entity, %{"name" => name, "position" => position}) do
      e = response["data"]

      {:ok,
       %{
         "tick" => response["tick"],
         "entity" => %{
           "name" => e["name"],
           "type" => e["type"],
           "unit_number" => e["unit_number"] || 0,
           "x_milli" => milli(e["position"]["x"]),
           "y_milli" => milli(e["position"]["y"]),
           "amount" => e["amount"] || 0,
           "status" => e["status_name"] || "not_applicable",
           "inventory" => stacks(e["inventory"]),
           "fuel" => stacks(e["fuel"]),
           "input" => stacks(e["input"]),
           "output" => stacks(e["output"])
         }
       }}
    end
  end

  def handle("InspectResources", %{"item" => item, "radius" => radius}, call, _)
      when is_integer(radius) and radius in 0..64 do
    with :ok <- item(item),
         {:ok, response} <- invoke(call, :inspect, %{"radius" => radius, "name" => item}) do
      resources =
        response["data"]["entities"]
        |> collection()
        |> Enum.filter(&(&1["type"] == "resource" and &1["name"] == item))
        |> Enum.map(fn e ->
          %{
            "name" => e["name"],
            "x_milli" => milli(e["position"]["x"]),
            "y_milli" => milli(e["position"]["y"]),
            "amount" => e["amount"]
          }
        end)

      {:ok,
       %{
         "tick" => response["tick"],
         "resources" => resources,
         "truncated" => response["data"]["truncated"] == true
       }}
    end
  end

  def handle("InspectAction", %{"id" => id}, call, _)
      when is_integer(id) and id in 1..2_147_483_647 do
    with {:ok, response} <- invoke(call, :action, %{"id" => id}) do
      {:ok, %{"tick" => response["tick"], "action" => action_summary(response["data"])}}
    end
  end

  def handle("InspectSimulation", args, call, _) when args == %{} do
    with {:ok, response} <- invoke(call, :inspect_simulation, %{}) do
      data = response["data"]

      {:ok,
       %{
         "tick" => response["tick"],
         "speed_milli" => milli(data["speed"]),
         "tick_paused" => data["tick_paused"],
         "connected_players" => data["connected_players"],
         "version" => data["version"]
       }}
    end
  end

  def handle("WalkTo", %{"position" => pos, "timeout_ticks" => ticks}, call, await) do
    with {:ok, position} <- position(pos),
         :ok <- ticks(ticks),
         {:ok, response} <-
           invoke(call, :walk_to, %{"position" => position, "timeout_ticks" => ticks}) do
      await_action(response, await)
    end
  end

  def handle(
        "Mine",
        %{"position" => pos, "item" => item, "count" => count, "timeout_ticks" => ticks},
        call,
        await
      ) do
    with {:ok, position} <- position(pos),
         :ok <- ticks(ticks),
         :ok <- count(count),
         :ok <- item(item),
         {:ok, response} <-
           invoke(call, :mine, %{
             "position" => position,
             "item" => item,
             "count" => count,
             "timeout_ticks" => ticks
           }) do
      await_action(response, await)
    end
  end

  def handle("Build", %{"position" => pos, "item" => item, "direction" => direction}, call, _) do
    with {:ok, position} <- position(pos),
         :ok <- item(item),
         true <- direction in ["north", "east", "south", "west"],
         {:ok, response} <-
           invoke(call, :build, %{
             "position" => position,
             "item" => item,
             "direction" => direction
           }) do
      receipt(response, 1)
    else
      false -> {:error, "direction must be north, east, south or west"}
      other -> other
    end
  end

  def handle(
        "Transfer",
        %{
          "position" => pos,
          "entity" => entity,
          "inventory" => inventory,
          "direction" => direction,
          "item" => item,
          "count" => count
        },
        call,
        _
      ) do
    with {:ok, position} <- position(pos),
         :ok <- count(count),
         :ok <- item(item),
         :ok <- item(entity),
         true <-
           inventory in ["fuel", "output", "input", "main"] and direction in ["take", "give"],
         {:ok, response} <-
           invoke(call, :transfer, %{
             "position" => position,
             "entity" => entity,
             "inventory" => inventory,
             "direction" => direction,
             "item" => item,
             "count" => count
           }) do
      receipt(response, count)
    else
      false -> {:error, "invalid inventory or transfer direction"}
      other -> other
    end
  end

  def handle("Stop", args, call, _) when args == %{} do
    with {:ok, response} <- invoke(call, :stop, %{}), do: receipt(response, 0)
  end

  def handle("Wait", %{"ticks" => ticks}, call, _) do
    with :ok <- ticks(ticks), {:ok, response} <- invoke(call, :inspect, %{"radius" => 0}) do
      wait_until(call, response["tick"] + ticks, System.monotonic_time(:millisecond) + 65_000)
    end
  end

  def handle(_, _, _, _), do: {:error, "invalid effect arguments"}

  defp wait_until(call, tick, deadline) do
    with {:ok, response} <- invoke(call, :inspect, %{"radius" => 0}) do
      cond do
        response["tick"] >= tick ->
          receipt(response, 0)

        System.monotonic_time(:millisecond) >= deadline ->
          {:fatal, :wait_timeout}

        true ->
          Process.sleep(100)
          wait_until(call, tick, deadline)
      end
    end
  end

  defp await_action(response, await) do
    id = response["data"]["id"]

    case await.(id) do
      {:ok, %{"ok" => true, "data" => %{"id" => ^id, "status" => "completed"} = data} = done} ->
        receipt(done, data["count"] || 0, id)

      {:ok, %{"ok" => true, "data" => %{"id" => ^id, "status" => status} = data}}
      when status in ["failed", "cancelled"] ->
        {:error, "action #{id} #{status}: #{inspect(data)}"}

      other ->
        {:fatal, {:action_unconfirmed, id, other}}
    end
  end

  defp invoke(call, method, args) do
    case call.(method, args) do
      {:ok, %{"ok" => true} = response} -> {:ok, response}
      {:ok, %{"ok" => false, "error" => error}} -> {:error, String.slice(inspect(error), 0, 1000)}
      other -> {:fatal, {:game_outcome_unconfirmed, method, other}}
    end
  end

  defp receipt(response, count, action_id \\ 0),
    do: {:ok, %{"tick" => response["tick"], "count" => count, "action_id" => action_id}}

  defp receipt_result({:ok, response}), do: %{response: response}
  defp receipt_result(other), do: %{unconfirmed: inspect(other)}
  defp collection(value) when is_list(value), do: value
  defp collection(value) when value == %{} or is_nil(value), do: []
  defp stacks(value), do: Enum.map(collection(value), &Map.take(&1, ["name", "quality", "count"]))

  defp milli(value), do: round(value * 1000)

  defp action_summary(a) do
    pos = a["position"]
    error = a["error"] || %{}

    %{
      "id" => a["id"],
      "kind" => a["kind"],
      "status" => a["status"],
      "count" => a["count"] || 0,
      "started_tick" => a["started_tick"],
      "deadline_tick" => a["deadline_tick"],
      "finished_tick" => a["finished_tick"] || 0,
      "has_position" => not is_nil(pos),
      "x_milli" => if(pos, do: milli(pos["x"]), else: 0),
      "y_milli" => if(pos, do: milli(pos["y"]), else: 0),
      "error_code" => error["code"] || "",
      "error_message" => error["message"] || ""
    }
  end

  defp position(%{"x2" => x, "y2" => y})
       when is_integer(x) and is_integer(y) and abs(x) <= 2_000_000 and abs(y) <= 2_000_000,
       do: {:ok, %{"x" => x / 2, "y" => y / 2}}

  defp position(_), do: {:error, "position requires bounded integer x2/y2 (half tiles)"}
  defp ticks(n) when is_integer(n) and n in 1..3600, do: :ok
  defp ticks(_), do: {:error, "ticks must be 1..3600"}
  defp count(n) when is_integer(n) and n in 1..1000, do: :ok
  defp count(_), do: {:error, "count must be 1..1000"}
  defp item(s) when is_binary(s) and byte_size(s) in 1..100, do: :ok
  defp item(_), do: {:error, "invalid item/entity name"}
end
