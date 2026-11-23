defmodule FactorioControl.Eyg.Combat do
  @moduledoc "Bounded threat observation and real character weapon bursts; tactics remain in EYG."
  defp scalar(k), do: %{"kind" => k}
  defp record(f), do: %{"kind" => "record", "fields" => Map.new(f)}

  def contracts do
    int = scalar("integer")
    text = scalar("string")
    bool = scalar("boolean")

    enemy =
      record(
        unit_number: int,
        name: text,
        x_milli: int,
        y_milli: int,
        health_milli: int,
        can_shoot: bool
      )

    %{
      "InspectCombat" => %{
        "argument" => record(radius: int),
        "result" =>
          record(
            tick: int,
            health_milli: int,
            selected_gun_slot: int,
            enemies: %{"kind" => "list", "items" => enemy},
            truncated: bool
          )
      },
      "Attack" => %{
        "argument" => record(unit_number: int, gun_slot: int, ticks: int),
        "result" =>
          record(
            tick: int,
            action_id: int,
            rounds_used: int,
            target_gone: bool,
            initial_health_milli: int,
            final_health_milli: int
          )
      }
    }
  end

  def handle("InspectCombat", %{"radius" => r} = args, call, _)
      when is_integer(r) and r in 1..64 do
    with {:ok, response} <- invoke(call, :inspect_combat, args) do
      d = response["data"]

      {:ok,
       %{
         "tick" => response["tick"],
         "health_milli" => round(d["health"] * 1000),
         "selected_gun_slot" => d["selected_gun_slot"],
         "enemies" => if(is_list(d["enemies"]), do: d["enemies"], else: []),
         "truncated" => d["truncated"]
       }}
    end
  end

  def handle(
        "Attack",
        %{"unit_number" => id, "gun_slot" => slot, "ticks" => ticks} = args,
        call,
        await
      )
      when is_integer(id) and id > 0 and id <= 9_007_199_254_740_991 and slot in 1..3 and
             ticks in 1..300 do
    with {:ok, response} <- invoke(call, :attack, args) do
      action_id = response["data"]["id"]

      case await.(action_id) do
        {:ok,
         %{
           "ok" => true,
           "tick" => tick,
           "data" => %{"id" => ^action_id, "status" => "completed"} = d
         }} ->
          {:ok,
           %{
             "tick" => tick,
             "action_id" => action_id,
             "rounds_used" => d["count"],
             "target_gone" => d["target_gone"],
             "initial_health_milli" => d["initial_health_milli"],
             "final_health_milli" => d["final_health_milli"]
           }}

        {:ok, %{"ok" => true, "data" => %{"id" => ^action_id, "status" => status} = d}}
        when status in ["failed", "cancelled"] ->
          {:error, "attack #{action_id} #{status}: #{inspect(d)}"}

        other ->
          {:fatal, {:action_unconfirmed, action_id, other}}
      end
    end
  end

  def handle(_, _, _, _), do: {:error, "invalid combat arguments"}

  defp invoke(call, method, args) do
    case call.(method, args) do
      {:ok, %{"ok" => true} = r} -> {:ok, r}
      {:ok, %{"ok" => false, "error" => e}} -> {:error, String.slice(inspect(e), 0, 1000)}
      other -> {:fatal, {:game_outcome_unconfirmed, method, other}}
    end
  end
end
