defmodule FactorioControl.Eyg.Equipment do
  @moduledoc "Typed character equipment inspection and metadata-preserving slot transfers."
  defp record(fields), do: %{"kind" => "record", "fields" => Map.new(fields)}
  defp scalar(kind), do: %{"kind" => kind}

  def contracts do
    int = scalar("integer")
    text = scalar("string")

    slot =
      record(
        inventory: text,
        slot: int,
        name: text,
        quality: text,
        count: int,
        health_milli: int,
        ammo: int
      )

    %{
      "InspectEquipment" => %{
        "argument" => record([]),
        "result" =>
          record(
            tick: int,
            slots: %{"kind" => "list", "items" => slot},
            candidates: %{"kind" => "list", "items" => slot},
            truncated: scalar("boolean"),
            empty_main_slots: %{"kind" => "list", "items" => int},
            main_size: int
          )
      },
      "Equip" => %{
        "argument" => record(inventory: text, slot: int, main_slot: int, direction: text),
        "result" => record(tick: int, count: int, action_id: int)
      }
    }
  end

  def handle("InspectEquipment", args, call) when args == %{} do
    with {:ok, r} <- invoke(call, :inspect_equipment, %{}) do
      data = r["data"]

      {:ok,
       %{
         "tick" => r["tick"],
         "slots" => collection(data["slots"]),
         "candidates" => collection(data["candidates"]),
         "truncated" => data["truncated"] == true,
         "empty_main_slots" => collection(data["empty_main_slots"]),
         "main_size" => data["main_size"] || 0
       }}
    end
  end

  def handle(
        "Equip",
        %{"inventory" => inv, "slot" => slot, "main_slot" => main, "direction" => direction} =
          args,
        call
      )
      when inv in ["armor", "guns", "ammo"] and is_integer(slot) and slot in 1..3 and
             is_integer(main) and main in 1..1000 and direction in ["equip", "unequip"] do
    with {:ok, r} <- invoke(call, :equip, args) do
      {:ok, %{"tick" => r["tick"], "count" => r["data"]["count"], "action_id" => 0}}
    end
  end

  def handle(_, _, _), do: {:error, "invalid equipment arguments"}
  defp collection(value) when is_list(value), do: value
  defp collection(_), do: []

  defp invoke(call, method, args) do
    case call.(method, args) do
      {:ok, %{"ok" => true} = r} -> {:ok, r}
      {:ok, %{"ok" => false, "error" => error}} -> {:error, String.slice(inspect(error), 0, 1000)}
      other -> {:fatal, {:game_outcome_unconfirmed, method, other}}
    end
  end
end
