defmodule FactorioControl.Eyg.Expansion do
  @moduledoc "Bounded infrastructure, research and terrain effects; no administrator operations."
  defp scalar(kind), do: %{"kind" => kind}
  defp record(fields), do: %{"kind" => "record", "fields" => Map.new(fields)}
  defp list(item), do: %{"kind" => "list", "items" => item}
  defp contract(argument, result), do: %{"argument" => argument, "result" => result}

  def contracts do
    int = scalar("integer")
    text = scalar("string")
    bool = scalar("boolean")
    position = record(x2: int, y2: int)
    stack = record(name: text, quality: text, count: int)
    receipt = record(tick: int, count: int, action_id: int)

    %{
      "InspectArea" =>
        contract(
          record(position: position, radius: int),
          record(
            tick: int,
            tiles: list(record(name: text, x: int, y: int, water: bool)),
            entities:
              list(
                record(
                  name: text,
                  type: text,
                  x_milli: int,
                  y_milli: int,
                  force: text,
                  health_milli: int,
                  max_health_milli: int
                )
              ),
            truncated: bool,
            tiles_complete: bool
          )
        ),
      "InspectWater" =>
        contract(
          record(radius: int),
          record(tick: int, tiles: list(record(name: text, x: int, y: int)), truncated: bool)
        ),
      "InspectTechnology" =>
        contract(
          record(name: text),
          record(
            tick: int,
            technology:
              record(
                name: text,
                enabled: bool,
                researched: bool,
                current: bool,
                progress_milli: int,
                prerequisites: list(record(name: text, researched: bool)),
                count: int,
                time_milli: int,
                ingredients: list(record(name: text, amount_milli: int)),
                trigger_type: text,
                trigger_item: text,
                trigger_entity: text,
                trigger_count: int
              )
          )
        ),
      "InspectMachine" =>
        contract(
          record(name: text, position: position),
          record(
            tick: int,
            machine:
              record(
                name: text,
                type: text,
                x_milli: int,
                y_milli: int,
                status: text,
                health_milli: int,
                max_health_milli: int,
                energy_joules: int,
                network_id: int,
                recipe: text,
                fuel: list(stack),
                input: list(stack),
                output: list(stack),
                ammo: list(stack),
                inventory: list(stack),
                fluids: list(record(name: text, amount_milli: int, temperature_milli: int))
              )
          )
        ),
      "SpawnBot" =>
        contract(
          record(position: position),
          record(tick: int, x_milli: int, y_milli: int, existing: bool)
        ),
      "Research" => contract(record(name: text), receipt),
      "SetChestLimit" => contract(record(name: text, position: position, slots: int), receipt),
      "BuildUnderground" =>
        contract(record(position: position, direction: text, end_type: text), receipt),
      "SetRecipe" => contract(record(name: text, position: position, recipe: text), receipt),
      "ConnectPower" => contract(record(from: position, to: position), receipt),
      "MineObject" =>
        contract(record(name: text, position: position, timeout_ticks: int), receipt),
      "HandCraft" => contract(record(recipe: text, count: int, timeout_ticks: int), receipt)
    }
  end

  def handle("InspectArea", %{"position" => pos, "radius" => radius}, call, _)
      when is_integer(radius) and radius in 1..8 do
    with {:ok, pos} <- position(pos),
         {:ok, r} <- invoke(call, :inspect_area, %{"position" => pos, "radius" => radius}) do
      d = r["data"]

      {:ok,
       %{
         "tick" => r["tick"],
         "truncated" => d["truncated"] == true,
         "tiles_complete" =>
           length(collection(d["tiles"])) == (2 * radius + 1) * (2 * radius + 1),
         "tiles" =>
           Enum.map(collection(d["tiles"]), fn t ->
             %{
               "name" => t["name"],
               "x" => round(t["position"]["x"]),
               "y" => round(t["position"]["y"]),
               "water" => t["water"] == true
             }
           end),
         "entities" =>
           Enum.map(collection(d["entities"]), fn e ->
             %{
               "name" => e["name"],
               "type" => e["type"],
               "x_milli" => milli(e["position"]["x"]),
               "y_milli" => milli(e["position"]["y"]),
               "force" => e["force"] || "",
               "health_milli" => milli(e["health"]),
               "max_health_milli" => milli(e["max_health"])
             }
           end)
       }}
    end
  end

  def handle("InspectWater", %{"radius" => radius}, call, _)
      when is_integer(radius) and radius in 1..64 do
    with {:ok, r} <- invoke(call, :inspect_water, %{"radius" => radius}) do
      {:ok,
       %{
         "tick" => r["tick"],
         "truncated" => r["data"]["truncated"] == true,
         "tiles" =>
           Enum.map(collection(r["data"]["tiles"]), fn t ->
             %{
               "name" => t["name"],
               "x" => round(t["position"]["x"]),
               "y" => round(t["position"]["y"])
             }
           end)
       }}
    end
  end

  def handle("InspectTechnology", %{"name" => name}, call, _) do
    with :ok <- name(name), {:ok, r} <- invoke(call, :inspect_technology, %{"name" => name}) do
      t = r["data"]

      {:ok,
       %{
         "tick" => r["tick"],
         "technology" => %{
           "name" => t["name"],
           "enabled" => t["enabled"] == true,
           "researched" => t["researched"] == true,
           "current" => t["current"] == true,
           "progress_milli" => milli(t["progress"]),
           "prerequisites" =>
             Enum.map(collection(t["prerequisites"]), fn p ->
               %{"name" => p["name"], "researched" => p["researched"] == true}
             end),
           "count" => round(t["count"] || 0),
           "time_milli" => milli(t["energy"]),
           "ingredients" =>
             Enum.map(collection(t["ingredients"]), fn i ->
               %{"name" => i["name"], "amount_milli" => milli(i["amount"])}
             end),
           "trigger_type" => t["trigger_type"] || "",
           "trigger_item" => t["trigger_item"] || "",
           "trigger_entity" => t["trigger_entity"] || "",
           "trigger_count" => round(t["trigger_count"] || 0)
         }
       }}
    end
  end

  def handle("InspectMachine", %{"name" => name, "position" => pos}, call, _) do
    with :ok <- name(name),
         {:ok, pos} <- position(pos),
         {:ok, r} <- invoke(call, :inspect_machine, %{"name" => name, "position" => pos}) do
      m = r["data"]

      {:ok,
       %{
         "tick" => r["tick"],
         "machine" => %{
           "name" => m["name"],
           "type" => m["type"],
           "x_milli" => milli(m["position"]["x"]),
           "y_milli" => milli(m["position"]["y"]),
           "status" => m["status_name"] || "not_applicable",
           "health_milli" => milli(m["health"]),
           "max_health_milli" => milli(m["max_health"]),
           "energy_joules" => round(m["energy"] || 0),
           "network_id" => m["network_id"] || 0,
           "recipe" => m["recipe"] || "",
           "fuel" => stacks(m["fuel"]),
           "input" => stacks(m["input"]),
           "output" => stacks(m["output"]),
           "ammo" => stacks(m["ammo"]),
           "inventory" => stacks(m["inventory"]),
           "fluids" =>
             Enum.map(collection(m["fluids"]), fn f ->
               %{
                 "name" => f["name"],
                 "amount_milli" => milli(f["amount"]),
                 "temperature_milli" => milli(f["temperature"])
               }
             end)
         }
       }}
    end
  end

  def handle("SetChestLimit", %{"name" => name, "position" => pos, "slots" => slots}, call, _)
      when is_integer(slots) and slots in 1..48 do
    with :ok <- name(name),
         {:ok, pos} <- position(pos),
         {:ok, r} <-
           invoke(call, :set_chest_limit, %{"name" => name, "position" => pos, "slots" => slots}),
         do: receipt(r, slots)
  end

  def handle(
        "BuildUnderground",
        %{"position" => pos, "direction" => direction, "end_type" => kind},
        call,
        _
      )
      when direction in ["north", "east", "south", "west"] and kind in ["input", "output"] do
    with {:ok, pos} <- position(pos),
         {:ok, r} <-
           invoke(call, :build_underground, %{
             "position" => pos,
             "direction" => direction,
             "end_type" => kind
           }),
         do: receipt(r, 1)
  end

  def handle("SpawnBot", %{"position" => pos}, call, _) do
    with {:ok, pos} <- position(pos), {:ok, r} <- invoke(call, :spawn, %{"position" => pos}) do
      p = r["data"]["position"]

      {:ok,
       %{
         "tick" => r["tick"],
         "x_milli" => milli(p["x"]),
         "y_milli" => milli(p["y"]),
         "existing" => r["data"]["existing"] == true
       }}
    end
  end

  def handle("Research", %{"name" => name}, call, _) do
    with :ok <- name(name), {:ok, r} <- invoke(call, :research, %{"name" => name}), do: receipt(r)
  end

  def handle("SetRecipe", %{"name" => name, "position" => pos, "recipe" => recipe}, call, _) do
    with :ok <- name(name),
         :ok <- name(recipe),
         {:ok, pos} <- position(pos),
         {:ok, r} <-
           invoke(call, :set_recipe, %{"name" => name, "position" => pos, "recipe" => recipe}),
         do: receipt(r)
  end

  def handle("ConnectPower", %{"from" => from, "to" => to}, call, _) do
    with {:ok, from} <- position(from),
         {:ok, to} <- position(to),
         {:ok, r} <- invoke(call, :connect_power, %{"from" => from, "to" => to}),
         do: receipt(r)
  end

  def handle(
        "MineObject",
        %{"name" => name, "position" => pos, "timeout_ticks" => ticks},
        call,
        await
      )
      when is_integer(ticks) and ticks in 1..3600 do
    with :ok <- name(name),
         {:ok, pos} <- position(pos),
         {:ok, r} <-
           invoke(call, :mine_object, %{
             "name" => name,
             "position" => pos,
             "timeout_ticks" => ticks
           }) do
      id = r["data"]["id"]

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
  end

  def handle(
        "HandCraft",
        %{"recipe" => recipe, "count" => count, "timeout_ticks" => ticks},
        call,
        await
      )
      when is_integer(count) and count in 1..100 and is_integer(ticks) and ticks in 1..3600 do
    with :ok <- name(recipe),
         {:ok, r} <-
           invoke(call, :hand_craft, %{
             "recipe" => recipe,
             "count" => count,
             "timeout_ticks" => ticks
           }) do
      id = r["data"]["id"]

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
  end

  def handle(effect, _, _, _) do
    if Map.has_key?(contracts(), effect),
      do: {:error, "invalid expansion effect arguments"},
      else: :unsupported
  end

  defp invoke(call, method, args) do
    case call.(method, args) do
      {:ok, %{"ok" => true} = r} -> {:ok, r}
      {:ok, %{"ok" => false, "error" => e}} -> {:error, String.slice(inspect(e), 0, 1000)}
      other -> {:fatal, {:game_outcome_unconfirmed, method, other}}
    end
  end

  defp receipt(r, count \\ 0, id \\ 0),
    do: {:ok, %{"tick" => r["tick"], "count" => count, "action_id" => id}}

  defp name(s) when is_binary(s) and byte_size(s) in 1..100, do: :ok
  defp name(_), do: {:error, "name must be 1..100 UTF-8 bytes"}

  defp position(%{"x2" => x, "y2" => y})
       when is_integer(x) and is_integer(y) and abs(x) <= 2_000_000 and abs(y) <= 2_000_000,
       do: {:ok, %{"x" => x / 2, "y" => y / 2}}

  defp position(_), do: {:error, "position requires bounded integer half tiles"}
  defp milli(n), do: round((n || 0) * 1000)
  defp collection(n) when is_list(n), do: n
  defp collection(n) when is_nil(n) or n == %{}, do: []
  defp stacks(n), do: Enum.map(collection(n), &Map.take(&1, ["name", "quality", "count"]))
end
