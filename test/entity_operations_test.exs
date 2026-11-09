defmodule FactorioControl.EntityOperationsTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 100, "data" => data}}

  test "InspectEntity exposes native rotation and mining capabilities through typed EYG" do
    call = fn :inspect_entity, %{"name" => "modded-machine"} ->
      ok(%{
        "name" => "modded-machine",
        "type" => "assembling-machine",
        "position" => %{"x" => 1.5, "y" => 2.5},
        "direction" => 12,
        "supports_direction" => true,
        "rotatable" => true,
        "minable" => false
      })
    end

    source = """
    match perform InspectEntity({name: "modded-machine", position: {x2: 3, y2: 5}}) {
      Ok(s) -> {{direction: s.entity.direction, supports_direction: s.entity.supports_direction,
        rotatable: s.entity.rotatable, minable: s.entity.minable}}
      Error(_) -> {{direction: 0, supports_direction: False({}), rotatable: False({}), minable: False({})}}
    }
    """

    assert {:ok,
            %{
              "value" => %{
                "direction" => 12,
                "supports_direction" => true,
                "rotatable" => true,
                "minable" => false
              }
            }, _} = Eyg.run(nil, source, effects: ["InspectEntity"], call: call)
  end

  test "missing inspection flags default conservatively" do
    call = fn :inspect_entity, _ ->
      ok(%{"name" => "iron-chest", "type" => "container", "position" => %{"x" => 0, "y" => 0}})
    end

    assert {:ok, %{"entity" => entity}} =
             Eyg.handle(
               "InspectEntity",
               %{"name" => "iron-chest", "position" => %{"x2" => 0, "y2" => 0}},
               call,
               nil
             )

    assert entity["direction"] == 0
    refute entity["supports_direction"]
    refute entity["rotatable"]
    refute entity["minable"]
  end

  test "Rotate forwards arbitrary prototype names with absolute headings exactly once" do
    for name <- ["assembling-machine-3", "fast-transport-belt", "modded-machine"] do
      owner = self()

      call = fn :rotate, args ->
        send(owner, {:rotated, args})
        ok(%{"name" => name, "direction" => 4})
      end

      assert {:ok, %{"count" => 0}} =
               Eyg.handle(
                 "Rotate",
                 %{"name" => name, "position" => %{"x2" => 3, "y2" => 5}, "direction" => "east"},
                 call,
                 nil
               )

      assert_received {:rotated,
                       %{
                         "name" => ^name,
                         "direction" => "east",
                         "position" => %{"x" => 1.5, "y" => 2.5}
                       }}

      refute_received {:rotated, _}
    end
  end

  test "a confirmed partial rotation error is catchable and never retried" do
    owner = self()

    call = fn :rotate, _ ->
      send(owner, :rotation_attempt)

      {:ok,
       %{
         "ok" => false,
         "tick" => 100,
         "error" => %{
           "code" => "rotation_incomplete",
           "message" => "original=0, current=4, requested=8; inspect before continuing"
         }
       }}
    end

    source = """
    match perform Rotate({name: "modded-machine", position: {x2: 3, y2: 5}, direction: "south"}) {
      Ok(_) -> {"unexpected success"}
      Error(e) -> {e}
    }
    """

    assert {:ok, %{"value" => error}, trace} =
             Eyg.run(nil, source, effects: ["Rotate"], call: call)

    assert error =~ "rotation_incomplete"
    assert error =~ "current=4"
    assert_received :rotation_attempt
    refute_received :rotation_attempt
    refute Enum.any?(trace, &match?(%{type: "cleanup_stop"}, &1))
  end

  test "MineObject forwards non-starter names and awaits the native mining action" do
    owner = self()

    call = fn :mine_object, args ->
      send(owner, {:mined, args})
      ok(%{"id" => 7})
    end

    source = """
    match perform MineObject({name: "modded-machine", position: {x2: 3, y2: 5}, timeout_ticks: 60}) {
      Ok(r) -> {r.count}
      Error(_) -> {0}
    }
    """

    assert {:ok, %{"value" => 1}, _} =
             Eyg.run(nil, source,
               effects: ["MineObject"],
               call: call,
               await: fn 7 -> ok(%{"id" => 7, "status" => "completed", "count" => 1}) end
             )

    assert_received {:mined, %{"name" => "modded-machine", "timeout_ticks" => 60}}
    refute_received {:mined, _}
  end
end
