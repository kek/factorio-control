defmodule FactorioControl.FactoryLayoutTest do
  use ExUnit.Case, async: true
  @layout Path.expand("../scenarios/expansion/layout.json", __DIR__)
  defp layout, do: JSON.decode!(File.read!(@layout))
  defp point(p), do: {p["x2"], p["y2"]}
  defp dimensions(%{"name" => "assembling-machine-1"}), do: {3, 3}
  defp dimensions(%{"name" => "splitter"}), do: {2, 1}
  defp dimensions(%{"name" => "gun-turret"}), do: {2, 2}
  defp dimensions(_), do: {1, 1}

  test "audited workshop objects, walls and turrets have no footprint overlaps" do
    l = layout()

    objects =
      l["objects"] ++
        Enum.map(l["walls"], &Map.put(&1, "name", "stone-wall")) ++
        Enum.map(l["turrets"], &Map.put(&1, "name", "gun-turret"))

    for {p, i} <- Enum.with_index(objects), q <- Enum.take(objects, i) do
      {pw, ph} = dimensions(p)
      {qw, qh} = dimensions(q)

      refute abs(p["x2"] - q["x2"]) < pw + qw and abs(p["y2"] - q["y2"]) < ph + qh,
             "overlapping #{inspect(p)} / #{inspect(q)}"
    end

    assert length(l["objects"]) == 139
    assert length(l["turrets"]) == 9

    assert l["objects"]
           |> Enum.filter(&Map.has_key?(&1, "recipe"))
           |> Enum.map(& &1["recipe"])
           |> Enum.sort() ==
             Enum.sort(["iron-gear-wheel", "firearm-magazine", "transport-belt"])
  end

  test "106 walls plus the deliberate service opening form the complete rectangle" do
    l = layout()
    walls = MapSet.new(l["walls"], &point/1)
    opening = MapSet.new(l["service_opening"], &point/1)
    assert MapSet.size(walls) == 106
    assert MapSet.size(opening) == 2
    assert MapSet.disjoint?(walls, opening)
    full = MapSet.union(walls, opening)

    expected =
      for x <- 91..129//2,
          y <- -77..-7//2,
          x in [91, 129] or y in [-77, -7],
          into: MapSet.new(),
          do: {x, y}

    assert full == expected
    inside = Enum.filter(l["turrets"], &(&1["x2"] in 91..129 and &1["y2"] in -77..-7))
    assert length(inside) == 5

    for {x, y} <- full do
      assert Enum.any?(inside, fn g ->
               :math.sqrt(:math.pow(x - g["x2"], 2) + :math.pow(y - g["y2"], 2)) / 2 <= 17
             end),
             "uncovered perimeter point #{inspect({x, y})}"
    end
  end

  test "small-pole wires stay within ordinary reach and underground ends are paired" do
    l = layout()

    poles =
      MapSet.new(Enum.filter(l["objects"], &(&1["name"] == "small-electric-pole")), &point/1)

    poles = MapSet.union(poles, MapSet.new([{73, -69}, {83, -57}]))

    for w <- l["wires"] do
      assert MapSet.member?(poles, point(w["from"]))
      assert MapSet.member?(poles, point(w["to"]))
      {x, y} = point(w["from"])
      {xx, yy} = point(w["to"])
      assert :math.sqrt(:math.pow(x - xx, 2) + :math.pow(y - yy, 2)) / 2 <= 7.5
    end

    undergrounds = Enum.filter(l["objects"], &(&1["name"] == "underground-belt"))
    assert length(undergrounds) == 8

    for input <- Enum.filter(undergrounds, &(&1["end_type"] == "input")) do
      assert Enum.any?(undergrounds, fn out ->
               out["end_type"] == "output" and out["direction"] == "east" and
                 input["direction"] == "east" and
                 out["y2"] == input["y2"] and (out["x2"] - input["x2"]) in 2..10
             end)
    end
  end
end
