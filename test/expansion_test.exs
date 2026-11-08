defmodule FactorioControl.ExpansionTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  @worker System.get_env("EYG_WORKER") ||
            Path.expand(
              "../../config/pi/agent/extensions/eyg-action/portable-worker.mjs",
              __DIR__
            )
  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 100, "data" => data}}

  defp run(code, effects, call, extra \\ []) do
    Eyg.run(nil, code, Keyword.merge([worker: @worker, effects: effects, call: call], extra))
  end

  test "area inspection converts half tiles, bounds queries, and reports observed terrain" do
    call = fn :inspect_area, %{"position" => %{"x" => 1.5, "y" => -2.0}, "radius" => 1} ->
      ok(%{
        "tiles" => [%{"name" => "water", "position" => %{"x" => 1, "y" => -2}, "water" => true}],
        "entities" => [
          %{
            "name" => "tree",
            "type" => "tree",
            "position" => %{"x" => 1.5, "y" => -2.5},
            "force" => "neutral",
            "health" => 50.5,
            "max_health" => 100
          }
        ],
        "truncated" => true
      })
    end

    code =
      "match perform InspectArea({position: {x2: 3, y2: -4}, radius: 1}) { Ok(s) -> {s} Error(_) -> {{tick: 0, tiles: [], entities: [], truncated: False({}), tiles_complete: False({})}} }"

    assert {:ok, %{"ok" => true, "value" => value}, _} = run(code, ["InspectArea"], call)
    assert hd(value["tiles"])["water"]
    refute value["tiles_complete"]
    assert hd(value["entities"])["health_milli"] == 50_500

    assert {:error, _} =
             Eyg.handle(
               "InspectArea",
               %{"position" => %{"x2" => 0, "y2" => 0}, "radius" => 9},
               fn _, _ -> flunk("must reject before game") end,
               nil
             )
  end

  test "SpawnBot is a typed, explicitly granted empty-character lifecycle action" do
    assert {:ok, %{"existing" => false, "x_milli" => 40_000}} =
             Eyg.handle(
               "SpawnBot",
               %{"position" => %{"x2" => 80, "y2" => -66}},
               fn :spawn, %{"position" => %{"x" => 40.0, "y" => -33.0}} ->
                 ok(%{"position" => %{"x" => 40, "y" => -33}, "existing" => false})
               end,
               nil
             )

    assert {:ok, %{"ok" => false}, _} =
             run("perform SpawnBot({position:{x2:80,y2:-66}})", ["InspectBot"], fn _, _ ->
               flunk("no spawn grant")
             end)
  end

  test "water survey is a bounded read-only tile query" do
    call = fn :inspect_water, %{"radius" => 64} ->
      ok(%{
        "tiles" => [%{"name" => "water", "position" => %{"x" => -1, "y" => 2}}],
        "truncated" => true
      })
    end

    assert {:ok, %{"tiles" => [%{"x" => -1}], "truncated" => true}} =
             Eyg.handle("InspectWater", %{"radius" => 64}, call, nil)

    assert {:error, _} =
             Eyg.handle(
               "InspectWater",
               %{"radius" => 65},
               fn _, _ -> flunk("unbounded query") end,
               nil
             )
  end

  test "technology reads expose normal trigger requirements without unlocking anything" do
    call = fn :inspect_technology, %{"name" => "electronics"} ->
      ok(%{
        "name" => "electronics",
        "enabled" => true,
        "researched" => false,
        "prerequisites" => [],
        "count" => 0,
        "energy" => 0,
        "ingredients" => [],
        "trigger_type" => "craft-item",
        "trigger_item" => "copper-plate",
        "trigger_count" => 1,
        "current" => false,
        "progress" => 0
      })
    end

    code =
      "match perform InspectTechnology({name: \"electronics\"}) { Ok(s) -> {s.technology.trigger_item} Error(e) -> {e} }"

    assert {:ok, %{"value" => "copper-plate"}, _} = run(code, ["InspectTechnology"], call)

    assert {:ok, %{"ok" => false}, _} =
             run("perform Research({name: \"electronics\"})", ["InspectTechnology"], fn _, _ ->
               flunk("no mutation grant")
             end)
  end

  test "machine reads preserve ammo, fluids and electric state" do
    call = fn :inspect_machine, _ ->
      ok(%{
        "name" => "boiler",
        "type" => "boiler",
        "position" => %{"x" => 2.5, "y" => 4},
        "status_name" => "working",
        "health" => 100,
        "max_health" => 200,
        "energy" => 12.5,
        "network_id" => 5,
        "recipe" => "",
        "fuel" => [],
        "input" => [],
        "output" => [],
        "inventory" => [],
        "ammo" => [%{"name" => "firearm-magazine", "quality" => "normal", "count" => 2}],
        "fluids" => [%{"name" => "steam", "amount" => 12.25, "temperature" => 165}]
      })
    end

    assert {:ok, %{"machine" => m}} =
             Eyg.handle(
               "InspectMachine",
               %{"name" => "boiler", "position" => %{"x2" => 5, "y2" => 8}},
               call,
               nil
             )

    assert m["energy_joules"] == 13
    assert hd(m["fluids"])["amount_milli"] == 12_250
    assert hd(m["ammo"])["count"] == 2
  end

  test "chest limits and underground endpoints reject unbounded or invalid configuration" do
    assert {:ok, %{"count" => 2}} =
             Eyg.handle(
               "SetChestLimit",
               %{"name" => "iron-chest", "position" => %{"x2" => 1, "y2" => 1}, "slots" => 2},
               fn :set_chest_limit, _ -> ok(%{}) end,
               nil
             )

    assert {:error, _} =
             Eyg.handle(
               "SetChestLimit",
               %{"name" => "iron-chest", "position" => %{"x2" => 1, "y2" => 1}, "slots" => 49},
               fn _, _ -> flunk("invalid limit") end,
               nil
             )

    assert {:ok, %{"count" => 1}} =
             Eyg.handle(
               "BuildUnderground",
               %{
                 "position" => %{"x2" => 1, "y2" => 1},
                 "direction" => "south",
                 "end_type" => "output"
               },
               fn :build_underground, a ->
                 assert a["end_type"] == "output"
                 ok(%{})
               end,
               nil
             )

    assert {:error, _} =
             Eyg.handle(
               "BuildUnderground",
               %{
                 "position" => %{"x2" => 1, "y2" => 1},
                 "direction" => "sideways",
                 "end_type" => "output"
               },
               fn _, _ -> flunk("invalid endpoint") end,
               nil
             )
  end

  test "immediate infrastructure actions call only their bounded method once" do
    for {effect, args, method} <- [
          {"Research", %{"name" => "automation"}, :research},
          {"SetRecipe",
           %{
             "name" => "assembling-machine-1",
             "position" => %{"x2" => 3, "y2" => 3},
             "recipe" => "iron-gear-wheel"
           }, :set_recipe},
          {"ConnectPower", %{"from" => %{"x2" => 1, "y2" => 1}, "to" => %{"x2" => 11, "y2" => 1}},
           :connect_power}
        ] do
      owner = self()

      assert {:ok, %{"count" => 0}} =
               Eyg.handle(
                 effect,
                 args,
                 fn ^method, params ->
                   send(owner, {:called, method, params})
                   ok(%{})
                 end,
                 nil
               )

      assert_received {:called, ^method, _}
      refute_received {:called, _, _}
    end
  end

  for {effect, method, source} <- [
        {"MineObject", :mine_object,
         "perform MineObject({name: \"tree-09\", position: {x2: 3, y2: 3}, timeout_ticks: 60})"},
        {"HandCraft", :hand_craft,
         "perform HandCraft({recipe: \"lab\", count: 1, timeout_ticks: 60})"}
      ] do
    test "#{effect} retains acceptance, completion, and unknown-outcome cleanup semantics" do
      method = unquote(method)

      source =
        "match " <>
          unquote(source) <> " { Ok(r) -> {r} Error(_) -> {{tick: 0, count: 0, action_id: 0}} }"

      call = fn ^method, _ -> ok(%{"id" => 7}) end

      assert {:ok, %{"value" => %{"count" => 1, "action_id" => 7}}, trace} =
               run(source, [unquote(effect)], call,
                 await: fn 7 -> ok(%{"id" => 7, "status" => "completed", "count" => 1}) end
               )

      assert Enum.any?(trace, &match?(%{type: "action_submission"}, &1))
      owner = self()

      unknown = fn m, _ ->
        send(owner, {:called, m})
        if m == method, do: {:error, {:unknown_outcome, :closed}}, else: ok(%{})
      end

      assert {:error, _, trace} = run(source, [unquote(effect)], unknown)
      assert_received {:called, ^method}
      assert_received {:called, :stop}
      refute_received {:called, _}
      assert List.last(trace).type == "cleanup_stop"
    end
  end
end
