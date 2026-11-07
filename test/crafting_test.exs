defmodule FactorioControl.CraftingTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  @worker System.get_env("EYG_WORKER") ||
            Path.expand(
              "../../config/pi/agent/extensions/eyg-action/portable-worker.mjs",
              __DIR__
            )
  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 100, "data" => data}}

  test "Craft submits once and reports actual produced items after completion" do
    owner = self()

    call = fn :craft, args ->
      send(owner, {:craft, args})
      ok(%{"id" => 12})
    end

    await = fn 12 -> ok(%{"id" => 12, "status" => "completed", "count" => 4}) end

    code =
      "match perform Craft({recipe: \"transport-belt\", count: 2, timeout_ticks: 600}) { Ok(x) -> {x.count} Error(_) -> {0} }"

    assert {:ok, %{"value" => 4}, trace} =
             Eyg.run(nil, code, worker: @worker, effects: ["Craft"], call: call, await: await)

    assert_received {:craft,
                     %{"recipe" => "transport-belt", "count" => 2, "timeout_ticks" => 600}}

    refute_received {:craft, _}
    assert Enum.any?(trace, &match?(%{type: "action_submission", method: "craft"}, &1))
    refute Enum.any?(trace, &match?(%{type: "cleanup_stop"}, &1))
  end

  test "unknown craft acceptance is fatal and triggers one cleanup stop" do
    owner = self()

    call = fn method, _ ->
      send(owner, {:called, method})
      if method == :craft, do: {:error, {:unknown_outcome, :closed}}, else: ok(%{})
    end

    assert {:error, {:game_outcome_unconfirmed, :craft, _}, trace} =
             Eyg.run(nil, "perform Craft({recipe: \"iron-chest\", count: 1, timeout_ticks: 600})",
               worker: @worker,
               effects: ["Craft"],
               call: call
             )

    assert_received {:called, :craft}
    assert_received {:called, :stop}
    refute_received {:called, _}
    assert List.last(trace).type == "cleanup_stop"
  end

  test "confirmed rejection is catchable and never triggers cleanup" do
    owner = self()

    call = fn :craft, _ ->
      send(owner, :submitted)

      {:ok,
       %{
         "ok" => false,
         "error" => %{"code" => "not_craftable", "message" => "Missing ingredients"}
       }}
    end

    code =
      "match perform Craft({recipe: \"iron-chest\", count: 1, timeout_ticks: 600}) { Ok(_) -> {1} Error(_) -> {0} }"

    assert {:ok, %{"value" => 0}, trace} =
             Eyg.run(nil, code, worker: @worker, effects: ["Craft"], call: call)

    assert_received :submitted
    refute Enum.any?(trace, &match?(%{type: "cleanup_stop"}, &1))
  end

  test "recipe inspection preserves ingredients and product quantities without granting craft" do
    call = fn :inspect_recipe, %{"name" => "transport-belt"} ->
      ok(%{
        "name" => "transport-belt",
        "enabled" => true,
        "categories" => ["crafting"],
        "energy" => 0.5,
        "craftable" => 7,
        "ingredients" => [%{"name" => "iron-plate", "type" => "item", "amount" => 1}],
        "products" => [%{"name" => "transport-belt", "type" => "item", "amount" => 2}]
      })
    end

    assert {:ok, %{"recipe" => r}} =
             Eyg.handle("InspectRecipe", %{"name" => "transport-belt"}, call, nil)

    assert r["ingredients"] == [
             %{"name" => "iron-plate", "type" => "item", "amount_milli" => 1000}
           ]

    assert r["products"] == [
             %{
               "name" => "transport-belt",
               "type" => "item",
               "min_milli" => 2000,
               "max_milli" => 2000,
               "probability_milli" => 1000
             }
           ]

    assert {:ok, %{"value" => 500}, _} =
             Eyg.run(
               nil,
               "match perform InspectRecipe({name: \"transport-belt\"}) { Ok(x) -> {x.recipe.time_milli} Error(_) -> {0} }",
               worker: @worker,
               effects: ["InspectRecipe"],
               call: call
             )
  end

  test "invalid craft requests do not call the game" do
    for args <- [
          %{"recipe" => "iron-chest", "count" => 0, "timeout_ticks" => 60},
          %{"recipe" => "iron-chest", "count" => 101, "timeout_ticks" => 60},
          %{"recipe" => "", "count" => 1, "timeout_ticks" => 60},
          %{"recipe" => "iron-chest", "count" => 1, "timeout_ticks" => 3601}
        ] do
      assert {:error, _} = Eyg.handle("Craft", args, fn _, _ -> flunk("no game call") end, nil)
    end
  end

  test "Rotate is a typed absolute-direction operation and rejects invalid headings before calling the game" do
    owner = self()

    call = fn :rotate, args ->
      send(owner, {:rotated, args})
      ok(%{})
    end

    code =
      "match perform Rotate({name: \"burner-inserter\", position: {x2: 51, y2: -77}, direction: \"north\"}) { Ok(_) -> {1} Error(_) -> {0} }"

    assert {:ok, %{"value" => 1}, _} =
             Eyg.run(nil, code, worker: @worker, effects: ["Rotate"], call: call)

    assert_received {:rotated,
                     %{
                       "name" => "burner-inserter",
                       "position" => %{"x" => 25.5, "y" => -38.5},
                       "direction" => "north"
                     }}

    assert {:error, _} =
             Eyg.handle(
               "Rotate",
               %{
                 "name" => "burner-inserter",
                 "position" => %{"x2" => 51, "y2" => -77},
                 "direction" => "sideways"
               },
               call,
               nil
             )

    refute_received {:rotated, _}
  end
end
