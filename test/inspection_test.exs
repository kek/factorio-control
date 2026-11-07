defmodule FactorioControl.InspectionTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  @worker System.get_env("EYG_WORKER") ||
            Path.expand(
              "../../config/pi/agent/extensions/eyg-action/portable-worker.mjs",
              __DIR__
            )

  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 900, "data" => data}}
  defp stack(name, count), do: %{"name" => name, "count" => count, "quality" => "normal"}

  defp action do
    %{
      "id" => 17,
      "kind" => "mine",
      "status" => "failed",
      "count" => 3,
      "started_tick" => 700,
      "deadline_tick" => 1000,
      "finished_tick" => 800,
      "position" => %{"x" => 45.5, "y" => 17.5},
      "error" => %{"code" => "target_lost", "message" => "Resource depleted"}
    }
  end

  defp backend(:inspect, %{"radius" => 0}) do
    ok(%{
      "position" => %{"x" => 43.87109375, "y" => 16.5546875},
      "health" => 249.5,
      "surface" => "nauvis",
      "inventory" => [stack("coal", 9)],
      "active_action" => action()
    })
  end

  defp backend(:inspect, %{"radius" => 5, "name" => "coal"}) do
    ok(%{
      "entities" => [
        %{
          "name" => "coal",
          "type" => "resource",
          "position" => %{"x" => 48.5, "y" => 17.5},
          "amount" => 666
        },
        %{
          "name" => "iron-ore",
          "type" => "resource",
          "position" => %{"x" => 29.5, "y" => -40.5},
          "amount" => 500
        }
      ],
      "truncated" => true
    })
  end

  defp backend(:inspect_entity, %{
         "name" => "stone-furnace",
         "position" => %{"x" => 29.0, "y" => -40.0}
       }) do
    ok(%{
      "name" => "stone-furnace",
      "type" => "furnace",
      "unit_number" => 241,
      "position" => %{"x" => 29, "y" => -40},
      "status" => 59,
      "status_name" => "full_output",
      "fuel" => [stack("coal", 10)],
      "input" => [stack("iron-ore", 4)],
      "output" => [stack("iron-plate", 100)]
    })
  end

  defp backend(:action, %{"id" => 17}), do: ok(action())

  defp backend(:inspect_simulation, args) when args == %{} do
    ok(%{"speed" => 0.5, "tick_paused" => false, "connected_players" => 1, "version" => "2.1.24"})
  end

  test "typed read-only effects expose the evidence needed to diagnose a stalled line" do
    owner = self()

    code = """
    let bot = match perform InspectBot({}) { Ok(x) -> {x.bot.x_milli} Error(_) -> {0} }
    let health = match perform InspectBot({}) { Ok(x) -> {x.bot.health_milli} Error(_) -> {0} }
    let status = match perform InspectEntity({name: "stone-furnace", position: {x2: 58, y2: -80}}) { Ok(x) -> {x.entity.status} Error(e) -> {e} }
    let coal = match perform InspectResources({item: "coal", radius: 5}) { Ok(x) -> {!list_fold(x.resources, 0, (r, n) -> {!int_add(r.amount, n)})} Error(_) -> {0} }
    let count = match perform InspectAction({id: 17}) { Ok(x) -> {x.action.count} Error(_) -> {0} }
    let speed = match perform InspectSimulation({}) { Ok(x) -> {x.speed_milli} Error(_) -> {0} }
    {bot: bot, health: health, status: status, coal: coal, count: count, speed: speed}
    """

    effects = ~w(InspectBot InspectEntity InspectResources InspectAction InspectSimulation)

    call = fn method, args ->
      send(owner, {:game_read, method})
      backend(method, args)
    end

    assert {:ok,
            %{
              "ok" => true,
              "value" => %{
                "bot" => 43871,
                "health" => 249_500,
                "status" => "full_output",
                "coal" => 666,
                "count" => 3,
                "speed" => 500
              }
            }, trace} =
             Eyg.run(nil, code, worker: @worker, effects: effects, call: call, timeout: 5000)

    requests = for %{"type" => "effect-request", "effect" => name} <- trace, do: name
    assert Enum.sort(Enum.uniq(requests)) == Enum.sort(effects)

    for method <- [:inspect, :inspect_entity, :action, :inspect_simulation] do
      assert_received {:game_read, ^method}
    end

    refute Enum.any?(trace, &match?(%{type: "action_submission"}, &1))
    refute Enum.any?(trace, &match?(%{type: "cleanup_stop"}, &1))
  end

  test "entity inspection retains separate inventories and symbolic status" do
    assert {:ok, %{"tick" => 900, "entity" => e}} =
             Eyg.handle(
               "InspectEntity",
               %{"name" => "stone-furnace", "position" => %{"x2" => 58, "y2" => -80}},
               &backend/2,
               nil
             )

    assert e["status"] == "full_output"
    assert e["fuel"] == [stack("coal", 10)]
    assert e["input"] == [stack("iron-ore", 4)]
    assert e["output"] == [stack("iron-plate", 100)]
    assert e["inventory"] == []
    assert e["x_milli"] == 29000 and e["y_milli"] == -40000
  end

  test "the diagnostic example runs with only inspection effects granted" do
    code = File.read!(Path.expand("../scenarios/inspect.eyg", __DIR__))

    call = fn
      :inspect, %{"radius" => 64, "name" => "coal"} ->
        backend(:inspect, %{"radius" => 5, "name" => "coal"})

      :inspect_entity,
      %{"name" => "burner-mining-drill", "position" => %{"x" => 29.0, "y" => -42.0}} ->
        ok(%{
          "name" => "burner-mining-drill",
          "type" => "mining-drill",
          "unit_number" => 242,
          "position" => %{"x" => 29, "y" => -42},
          "status_name" => "no_fuel",
          "fuel" => %{}
        })

      method, args ->
        backend(method, args)
    end

    assert {:ok, %{"ok" => true, "value" => result}, _} =
             Eyg.run(nil, code,
               worker: @worker,
               effects: ~w(InspectBot InspectEntity InspectResources InspectSimulation),
               call: call
             )

    assert result["furnace"]["status"] == "full_output"
    assert result["furnace"]["output"] == [stack("iron-plate", 100)]
    assert result["drill"]["status"] == "no_fuel"
    assert result["drill"]["fuel"] == []

    assert result["coal"] == %{
             "tiles" => 1,
             "remaining" => 666,
             "truncated" => true,
             "error" => ""
           }

    assert result["bot"]["inventory"] == [stack("coal", 9)]
  end

  test "bot and resource inspections normalize absent collections and preserve truncation" do
    call = fn :inspect, _ ->
      ok(%{
        "position" => %{"x" => 0, "y" => 0},
        "health" => 250,
        "surface" => "nauvis",
        "inventory" => %{},
        "entities" => %{},
        "truncated" => true
      })
    end

    assert {:ok, %{"bot" => %{"inventory" => [], "active_actions" => []}}} =
             Eyg.handle("InspectBot", %{}, call, nil)

    assert {:ok, %{"resources" => [], "truncated" => true}} =
             Eyg.handle("InspectResources", %{"item" => "coal", "radius" => 5}, call, nil)
  end

  test "action inspection retains partial progress, errors, and target positions" do
    assert {:ok, %{"action" => a}} = Eyg.handle("InspectAction", %{"id" => 17}, &backend/2, nil)
    assert a["count"] == 3
    assert a["error_code"] == "target_lost"
    assert a["error_message"] == "Resource depleted"
    assert a["has_position"] and a["x_milli"] == 45500
    assert a["finished_tick"] == 800
  end

  test "unknown entities and expired actions are catchable read errors without cleanup" do
    for {effect, args, method, code} <- [
          {"InspectEntity",
           %{"name" => "stone-furnace", "position" => %{"x2" => 58, "y2" => -80}},
           :inspect_entity, "not_found"},
          {"InspectAction", %{"id" => 999}, :action, "unknown_action"}
        ] do
      call = fn actual, _ ->
        assert actual == method
        {:ok, %{"ok" => false, "error" => %{"code" => code, "message" => "Unavailable"}}}
      end

      assert {:error, error} = Eyg.handle(effect, args, call, nil)
      assert error =~ code
    end
  end

  test "invalid inspection arguments are rejected before any game call" do
    for {effect, args} <- [
          {"InspectBot", %{"extra" => 1}},
          {"InspectEntity",
           %{"name" => "stone-furnace", "position" => %{"x2" => 0.5, "y2" => 0}}},
          {"InspectEntity", %{"name" => "", "position" => %{"x2" => 0, "y2" => 0}}},
          {"InspectResources", %{"item" => "coal", "radius" => 65}},
          {"InspectResources", %{"item" => "", "radius" => 5}},
          {"InspectAction", %{"id" => 0}},
          {"InspectAction", %{"id" => 2_147_483_648}},
          {"InspectSimulation", %{"extra" => 1}}
        ] do
      assert {:error, _} =
               Eyg.handle(effect, args, fn _, _ -> flunk("read must not be sent") end, nil)
    end
  end
end
