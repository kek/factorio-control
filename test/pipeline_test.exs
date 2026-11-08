defmodule FactorioControl.PipelineTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  @worker FactorioControl.Eyg.Worker.path()
  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 100, "data" => data}}

  defp run_phase(phase, reads) do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    call = fn method, args ->
      Agent.update(calls, &[{method, args} | &1])

      if method in [:walk_to, :mine, :craft] do
        ok(%{"id" => 1})
      else
        reads.(method, args)
      end
    end

    code = File.read!(Path.expand("../scenarios/iron-pipeline/#{phase}.eyg", __DIR__))

    result =
      Eyg.run(nil, code,
        worker: @worker,
        call: call,
        await: fn 1 -> ok(%{"id" => 1, "status" => "completed", "count" => 1}) end
      )

    {result, Agent.get(calls, &Enum.reverse/1)}
  end

  test "build phase creates four physical lanes while reusing the POC drill and furnace" do
    {result, calls} =
      run_phase("build", fn
        :inspect, %{"radius" => 0} ->
          ok(%{
            "position" => %{"x" => 56, "y" => 21},
            "health" => 250,
            "surface" => "nauvis",
            "inventory" => [%{"name" => "coal", "count" => 150, "quality" => "normal"}]
          })

        method, _ when method in [:build, :transfer] ->
          ok(%{})
      end)

    assert {:ok, %{"value" => %{"success" => true}}, _} = result
    builds = for {:build, a} <- calls, do: a
    assert Enum.count(builds, &(&1["item"] == "burner-mining-drill")) == 3
    assert Enum.count(builds, &(&1["item"] == "stone-furnace")) == 3
    assert Enum.count(builds, &(&1["item"] == "iron-chest")) == 4
    inserters = Enum.filter(builds, &(&1["item"] == "burner-inserter"))
    assert Enum.map(inserters, & &1["position"]["x"]) == [25.5, 29.5, 33.5, 37.5]
    assert Enum.all?(inserters, &(&1["direction"] == "north"))
    assert Enum.sum(for {:transfer, a} <- calls, do: a["count"]) == 132
  end

  test "preparation explicitly mines and crafts the prerequisite materials for the coal station" do
    {result, calls} =
      run_phase("prepare", fn method, _ when method in [:build, :transfer] -> ok(%{}) end)

    assert {:ok, %{"value" => %{"success" => true}}, _} = result
    assert Enum.sum(for {:mine, a} <- calls, do: a["count"]) == 40

    assert for({:craft, a} <- calls, into: %{}, do: {a["recipe"], a["count"]}) ==
             %{"stone-furnace" => 8, "iron-gear-wheel" => 19, "burner-mining-drill" => 2}

    assert for({:build, a} <- calls, do: a["direction"]) == ["east", "west"]
  end

  test "fuel collection avoids covered coal tiles and leaves five coal in each drill" do
    {result, calls} =
      run_phase("fuel", fn
        :inspect, %{"name" => "coal"} ->
          ok(%{
            "truncated" => false,
            "entities" => [
              %{
                "name" => "coal",
                "type" => "resource",
                "position" => %{"x" => 59.5, "y" => 18.5},
                "amount" => 1800
              },
              %{
                "name" => "coal",
                "type" => "resource",
                "position" => %{"x" => 59.5, "y" => 21.5},
                "amount" => 900
              }
            ]
          })

        :inspect_entity, %{"position" => pos} ->
          ok(%{
            "name" => "burner-mining-drill",
            "type" => "mining-drill",
            "position" => pos,
            "status_name" => "working",
            "fuel" => [%{"name" => "coal", "count" => 45, "quality" => "normal"}]
          })

        :transfer, _ ->
          ok(%{})
      end)

    assert {:ok, %{"value" => %{"success" => true}}, _} = result
    mines = for {:mine, a} <- calls, do: a
    assert length(mines) == 3
    assert Enum.all?(mines, &(&1["position"] == %{"x" => 59.5, "y" => 21.5}))
    assert for({:transfer, a} <- calls, do: a["count"]) == [40, 40]
  end

  test "service corrects inserter direction and only replenishes missing fuel" do
    {result, calls} =
      run_phase("service", fn
        :inspect_entity, %{"name" => name, "position" => pos} ->
          {type, fuel} =
            cond do
              pos["y"] == 18.0 -> {"mining-drill", 50}
              name == "stone-furnace" -> {"furnace", if(pos["x"] == 29.0, do: 20, else: 2)}
              name == "burner-inserter" -> {"inserter", 3}
              true -> {"mining-drill", 0}
            end

          ok(%{
            "name" => name,
            "type" => type,
            "position" => pos,
            "status_name" => "normal",
            "fuel" => [%{"name" => "coal", "quality" => "normal", "count" => fuel}]
          })

        method, _ when method in [:rotate, :transfer] ->
          ok(%{})
      end)

    assert {:ok, %{"value" => %{"success" => true}}, _} = result
    rotations = for {:rotate, args} <- calls, do: args
    assert Enum.map(rotations, & &1["position"]["x"]) == [25.5, 29.5, 33.5, 37.5]
    assert Enum.all?(rotations, &(&1["direction"] == "north"))

    assert Enum.sum(for {:transfer, %{"direction" => "take"} = args} <- calls, do: args["count"]) ==
             90

    assert Enum.sum(for {:transfer, %{"direction" => "give"} = args} <- calls, do: args["count"]) ==
             96
  end
end
