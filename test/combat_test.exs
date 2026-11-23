defmodule FactorioControl.CombatTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg
  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 42, "data" => data}}

  test "combat arguments and grants fail closed" do
    for args <- [
          %{"unit_number" => 0, "gun_slot" => 1, "ticks" => 60},
          %{"unit_number" => 1, "gun_slot" => 4, "ticks" => 60},
          %{"unit_number" => 1, "gun_slot" => 1, "ticks" => 301}
        ] do
      assert {:error, _} =
               Eyg.Combat.handle("Attack", args, fn _, _ -> flunk("no dispatch") end, nil)
    end

    assert {:ok, %{"ok" => false}, _} =
             Eyg.run(nil, "perform Attack({unit_number:1,gun_slot:1,ticks:1})",
               effects: ["InspectBot"],
               call: fn _, _ -> flunk("ungranted") end
             )

    for effect <- ["InspectCombat", "Attack"], do: assert(effect in Eyg.Adapter.effects())
  end

  test "example chooses a shootable target with fresh health and actual selected gun" do
    source = File.read!("scenarios/combat/burst.eyg")

    for health <- [250_000, 100_000], enemy_present <- [true, false] do
      parent = self()

      call = fn
        :inspect_combat, %{"radius" => 32} ->
          enemies =
            if enemy_present,
              do: [
                %{
                  "unit_number" => 7,
                  "name" => "small-biter",
                  "x_milli" => 2000,
                  "y_milli" => 0,
                  "health_milli" => 15000,
                  "can_shoot" => true
                }
              ],
              else: []

          ok(%{
            "health" => health / 1000,
            "selected_gun_slot" => 2,
            "enemies" => enemies,
            "truncated" => false
          })

        :attack, %{"unit_number" => 7, "gun_slot" => 2, "ticks" => 60} ->
          send(parent, :attacked)
          ok(%{"id" => 9})
      end

      await = fn 9 ->
        ok(%{
          "id" => 9,
          "status" => "completed",
          "count" => 3,
          "target_gone" => true,
          "initial_health_milli" => 15000,
          "final_health_milli" => 0
        })
      end

      assert {:ok, %{"ok" => true, "value" => value}, _} =
               Eyg.run(nil, source,
                 effects: ["InspectCombat", "Attack"],
                 call: call,
                 await: await
               )

      if health >= 150_000 and enemy_present do
        assert value["engaged"]
        assert value["rounds"] == 3
        assert_received :attacked
      else
        refute value["engaged"]
        refute_received :attacked
      end
    end
  end

  test "lost attack reply triggers existing stop cleanup, never a second burst" do
    parent = self()

    call = fn
      :attack, _ ->
        send(parent, :burst)
        {:error, :lost_reply}

      :stop, %{} ->
        send(parent, :stopped)
        ok(%{})
    end

    assert {:error, _, trace} =
             Eyg.run(nil, "perform Attack({unit_number:7,gun_slot:1,ticks:60})",
               effects: ["Attack"],
               call: call
             )

    assert_received :burst
    refute_received :burst
    assert_received :stopped
    assert Enum.any?(trace, &(&1[:type] == "cleanup_stop"))
  end
end
