defmodule FactorioControl.EquipmentTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  test "equipment is explicitly available in gameplay adapter" do
    for effect <- ["Equip", "InspectEquipment"] do
      assert effect in Eyg.Adapter.effects()
      assert Map.has_key?(Eyg.contracts(), effect)
    end
  end

  test "invalid equipment arguments never dispatch" do
    for args <- [
          %{"inventory" => "main", "slot" => 1, "main_slot" => 1, "direction" => "equip"},
          %{"inventory" => "guns", "slot" => 0, "main_slot" => 1, "direction" => "equip"},
          %{"inventory" => "ammo", "slot" => 1, "main_slot" => 1001, "direction" => "equip"},
          %{"inventory" => "armor", "slot" => 1, "main_slot" => 1, "direction" => "swap"}
        ] do
      assert {:error, _} =
               Eyg.Equipment.handle("Equip", args, fn _, _ -> flunk("no dispatch") end)
    end
  end

  test "empty observations normalize; no character is an explicit error" do
    code =
      "match perform InspectEquipment({}) {Ok(s)->{{slots:s.slots,error:\"\"}} Error(e)->{{slots:[],error:e}}}"

    for {data, error} <- [
          {%{
             "ok" => true,
             "tick" => 1,
             "data" => %{"slots" => [], "candidates" => %{}, "truncated" => false}
           }, false},
          {%{"ok" => false, "tick" => 1, "error" => %{"code" => "no_character"}}, true}
        ] do
      assert {:ok, %{"value" => value}, _} =
               Eyg.run(nil, code,
                 effects: ["InspectEquipment"],
                 call: fn :inspect_equipment, %{} -> {:ok, data} end
               )

      assert value["error"] != "" == error
      assert value["slots"] == []
    end
  end

  test "ungranted equipment effects are rejected before dispatch" do
    assert {:ok, %{"ok" => false}, _} =
             Eyg.run(
               nil,
               "perform Equip({inventory:\"armor\",slot:1,main_slot:1,direction:\"equip\"})",
               effects: ["InspectBot"],
               call: fn _, _ -> flunk("no grant") end
             )
  end
end
