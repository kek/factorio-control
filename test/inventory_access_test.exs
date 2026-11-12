defmodule FactorioControl.InventoryAccessTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 100, "data" => data}}

  test "both transfer effects accept module slots without changing selection or counts" do
    for {effect, method, extra} <- [
          {"Transfer", :transfer, ""},
          {"TransferQuality", :transfer_quality, ", quality: \"rare\""}
        ] do
      owner = self()

      call = fn ^method, args ->
        assert args["inventory"] == "modules"
        assert args["item"] == "speed-module"
        assert args["count"] == 3
        send(owner, :called)
        ok(%{"count" => 2, "quality" => args["quality"] || "normal"})
      end

      source = """
      match perform #{effect}({entity: "modded-machine", position: {x2: 1, y2: 1},
        inventory: "modules", direction: "give", item: "speed-module", count: 3#{extra}}) {
        Ok(r) -> {r.count}
        Error(_) -> {0}
      }
      """

      assert {:ok, %{"value" => 2}, _} = Eyg.run(nil, source, effects: [effect], call: call)
      assert_received :called
      refute_received :called
    end
  end

  test "module contents are exposed by both typed inspection effects" do
    for {effect, method, field} <- [
          {"InspectEntity", :inspect_entity, "entity"},
          {"InspectMachine", :inspect_machine, "machine"}
        ] do
      modules = [%{"name" => "speed-module", "quality" => "rare", "count" => 2}]

      call = fn ^method, _ ->
        ok(%{
          "name" => "modded-machine",
          "type" => "assembling-machine",
          "position" => %{"x" => 0.5, "y" => 0.5},
          "health" => 100,
          "max_health" => 100,
          "modules" => modules
        })
      end

      source = """
      match perform #{effect}({name: "modded-machine", position: {x2: 1, y2: 1}}) {
        Ok(s) -> {s.#{field}.modules}
        Error(_) -> {[]}
      }
      """

      assert {:ok, %{"value" => ^modules}, trace} =
               Eyg.run(nil, source, effects: [effect], call: call)

      refute Enum.any?(trace, &match?(%{type: "action_submission"}, &1))
    end
  end

  test "absent or unsupported module observations normalize to empty lists" do
    for effect <- ["InspectEntity", "InspectMachine"] do
      call = fn _, _ ->
        ok(%{
          "name" => "iron-chest",
          "type" => "container",
          "position" => %{"x" => 0.5, "y" => 0.5},
          "health" => 100,
          "max_health" => 100
        })
      end

      assert {:ok, response} =
               Eyg.handle(
                 effect,
                 %{"name" => "iron-chest", "position" => %{"x2" => 1, "y2" => 1}},
                 call,
                 nil
               )

      entity = response[if(effect == "InspectEntity", do: "entity", else: "machine")]
      assert entity["modules"] == []
    end
  end

  test "invalid selector names never reach the game" do
    for effect <- ["Transfer", "TransferQuality"] do
      args = %{
        "entity" => "assembling-machine-2",
        "position" => %{"x2" => 1, "y2" => 1},
        "inventory" => "module",
        "direction" => "give",
        "item" => "speed-module",
        "count" => 1
      }

      args = if effect == "TransferQuality", do: Map.put(args, "quality", "rare"), else: args

      assert {:error, _} =
               Eyg.handle(
                 effect,
                 args,
                 fn _, _ -> flunk("invalid selector reached game") end,
                 nil
               )
    end
  end

  test "native module rejection is returned without retrying another inventory" do
    owner = self()

    call = fn :transfer_quality, args ->
      assert args["inventory"] == "modules"
      send(owner, :called)

      {:ok,
       %{
         "ok" => false,
         "tick" => 100,
         "error" => %{
           "code" => "inventory_full",
           "message" => "module incompatible or inventory full"
         }
       }}
    end

    source = """
    match perform TransferQuality({entity: "assembling-machine-2", position: {x2: 1, y2: 1},
      inventory: "modules", direction: "give", item: "productivity-module", quality: "rare", count: 1}) {
      Ok(_) -> {"unexpected success"}
      Error(e) -> {e}
    }
    """

    assert {:ok, %{"value" => error}, _} =
             Eyg.run(nil, source, effects: ["TransferQuality"], call: call)

    assert error =~ "inventory_full"
    assert_received :called
    refute_received :called
  end
end
