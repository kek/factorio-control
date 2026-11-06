defmodule FactorioControl.LiveTest do
  use ExUnit.Case, async: false
  alias FactorioControl.{Bot, Rcon}
  @moduletag :live

  defp connect do
    {:ok, c} = Rcon.start_link(password: System.fetch_env!("FACTORIO_RCON_PASSWORD"))
    c
  end

  defp call(c, method, args \\ %{}) do
    {:ok, %{"ok" => true, "data" => data}} = Bot.call(c, method, args)
    data
  end

  defp reject(c, method, args, code) do
    assert {:ok, %{"ok" => false, "error" => %{"code" => ^code}}} = Bot.call(c, method, args)
  end

  defp admin(c, source) do
    {:ok, json} = Rcon.lua(c, source)
    result = JSON.decode!(json)
    refute result["ok"] == false, inspect(result)
    result
  end

  defp item_count(snapshot, name) do
    case snapshot["inventory"] do
      list when is_list(list) ->
        Enum.reduce(list, 0, fn item, sum ->
          sum + if(item["name"] == name, do: item["count"], else: 0)
        end)

      _ ->
        0
    end
  end

  test "real placement rollback, transfers, bounded actions, cancellation, and reconnect" do
    c = connect()
    call(c, :spawn)
    snapshot = call(c, :inspect, %{"radius" => 0})
    assert is_nil(snapshot["active_action"]), "Do not run live tests alongside another bot plan"
    %{"x" => x, "y" => y} = snapshot["position"]
    # Explicit test fixture only: two chest items and two wood. The gameplay
    # interface has no item-grant operation. Cleanup returns inventory to baseline.
    setup =
      admin(c, """
      local pos={x=#{x},y=#{y}}
      local c=nil
      for _,e in pairs(game.surfaces.nauvis.find_entities_filtered{name='character',position=pos,radius=0.1}) do
        if e.position.x==pos.x and e.position.y==pos.y then c=e break end
      end
      assert(c,'Could not identify bot character')
      local free=c.surface.find_non_colliding_position('wooden-chest',{x=pos.x+2,y=pos.y},3,0.5)
      assert(free,'No fixture position')
      free={x=math.floor(free.x)+0.5,y=math.floor(free.y)+0.5}
      assert((free.x-pos.x)^2+(free.y-pos.y)^2<=c.build_distance^2,'No fixture position in reach')
      assert(c.surface.can_place_entity{name='wooden-chest',position=free,force=c.force},'Fixture position blocked')
      assert(c.can_insert{name='wooden-chest',count=2} and c.can_insert{name='wood',count=2},'Fixture inventory full')
      assert(c.insert{name='wooden-chest',count=2}==2)
      assert(c.insert{name='wood',count=2}==2)
      rcon.print(helpers.table_to_json({unit=c.unit_number,position=free}))
      """)

    chest_pos = setup["position"]
    unit = setup["unit"]
    initial_chests = item_count(snapshot, "wooden-chest")

    try do
      reject(
        c,
        :build,
        %{"item" => "wooden-chest", "position" => %{"x" => x + 100, "y" => y}},
        "out_of_reach"
      )

      reject(c, :build, %{"item" => "stone-furnace", "position" => chest_pos}, "no_item")

      reject(
        c,
        :build,
        %{"item" => "wooden-chest", "position" => chest_pos, "direction" => "nonsense"},
        "invalid_argument"
      )

      reject(
        c,
        :build,
        %{
          "item" => "wooden-chest",
          "position" => %{"x" => chest_pos["x"] + 0.1, "y" => chest_pos["y"]}
        },
        "invalid_argument"
      )

      built = call(c, :build, %{"item" => "wooden-chest", "position" => chest_pos})
      assert built["name"] == "wooden-chest"
      assert built["position"] == chest_pos

      assert item_count(call(c, :inspect, %{"radius" => 0}), "wooden-chest") == initial_chests + 1
      reject(c, :build, %{"item" => "wooden-chest", "position" => chest_pos}, "blocked")
      assert item_count(call(c, :inspect, %{"radius" => 0}), "wooden-chest") == initial_chests + 1

      transfer = %{
        "entity" => "wooden-chest",
        "position" => chest_pos,
        "inventory" => "main",
        "item" => "wood",
        "count" => 2
      }

      call(c, :transfer, Map.put(transfer, "direction", "give"))

      reject(
        c,
        :transfer,
        transfer |> Map.put("direction", "take") |> Map.put("count", 3),
        "no_item"
      )

      call(c, :transfer, Map.put(transfer, "direction", "take"))
      reject(c, :action, %{"id" => 2_147_483_647}, "unknown_action")
      reject(c, :walk_to, %{"position" => %{"x" => "bad", "y" => y}}, "invalid_argument")

      %{"id" => id} =
        call(c, :walk_to, %{"position" => %{"x" => x + 100, "y" => y}, "timeout_ticks" => 600})

      reject(c, :build, %{"item" => "wooden-chest", "position" => chest_pos}, "busy")
      call(c, :stop)
      assert %{"status" => "cancelled"} = call(c, :action, %{"id" => id})

      %{"id" => deadline_id} =
        call(c, :walk_to, %{"position" => %{"x" => x + 100, "y" => y}, "timeout_ticks" => 1})

      assert {:ok, %{"data" => %{"status" => "failed", "error" => %{"code" => "timeout"}}}} =
               Bot.await(c, deadline_id)

      # A new connection can query terminal action IDs; it never reissues them.
      reconnect = connect()

      try do
        assert %{"status" => "failed"} = call(reconnect, :action, %{"id" => deadline_id})
        a = call(reconnect, :inspect, %{"radius" => 0})["position"]
        Process.sleep(150)
        assert call(reconnect, :inspect, %{"radius" => 0})["position"] == a
      after
        Rcon.close(reconnect)
      end
    after
      call(c, :stop)

      admin(c, """
      local c=game.get_entity_by_unit_number(#{unit})
      assert(c and c.valid)
      local chest=c.surface.find_entity('wooden-chest',{x=#{chest_pos["x"]},y=#{chest_pos["y"]}})
      if chest then assert(c.mine_entity(chest)) end
      assert(c.remove_item{name='wooden-chest',count=2}==2)
      assert(c.remove_item{name='wood',count=2}==2)
      rcon.print(helpers.table_to_json({cleaned=true}))
      """)

      Rcon.close(c)
    end
  end
end
