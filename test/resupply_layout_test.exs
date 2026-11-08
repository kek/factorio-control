defmodule FactorioControl.ResupplyLayoutTest do
  use ExUnit.Case, async: true
  @base Path.expand("../scenarios/expansion/layout.json", __DIR__)
  @path Path.expand("../scenarios/resupply/layout.json", __DIR__)
  defp key(o), do: {o["name"], o["x2"], o["y2"]}
  defp point(o), do: {o["x2"], o["y2"]}

  defp layout do
    base = JSON.decode!(File.read!(@base))
    delta = JSON.decode!(File.read!(@path))

    objects =
      base["objects"] ++
        Enum.map(base["turrets"], &Map.put(&1, "name", "gun-turret")) ++
        Enum.map(base["walls"], &Map.put(&1, "name", "stone-wall"))

    removed = MapSet.new(delta["removed_base_objects"], &key/1)
    objects = objects |> Enum.reject(&MapSet.member?(removed, key(&1))) |> Map.new(&{key(&1), &1})

    objects =
      Enum.reduce(
        delta["added_objects"] ++
          delta["existing_pole_references"] ++ [delta["copper"]["existing_drill"]],
        objects,
        fn o, acc -> Map.put(acc, key(o), o) end
      )
      |> Map.values()

    {delta, objects}
  end

  defp dims(o) do
    {w, h} =
      case o["name"] do
        "splitter" -> {2, 1}
        n when n in ["gun-turret", "stone-furnace", "burner-mining-drill"] -> {2, 2}
        _ -> {1, 1}
      end

    if o["direction"] in ["east", "west"], do: {h, w}, else: {w, h}
  end

  defp vector("north"), do: {0, -2}
  defp vector("south"), do: {0, 2}
  defp vector("east"), do: {2, 0}
  defp vector("west"), do: {-2, 0}
  defp plus({x, y}, {dx, dy}), do: {x + dx, y + dy}

  defp cells(o) do
    {w, h} = dims(o)
    for dx <- (1 - w)..(w - 1)//2, dy <- (1 - h)..(h - 1)//2, do: {o["x2"] + dx, o["y2"] + dy}
  end

  defp transport?(o), do: o["name"] in ["transport-belt", "underground-belt", "splitter"]

  defp graph(objects) do
    transports = Enum.filter(objects, &transport?/1)
    by_cell = Map.new(for o <- transports, cell <- cells(o), do: {cell, o})

    graph =
      Map.new(by_cell, fn {p, o} ->
        next =
          if o["name"] == "underground-belt" and o["end_type"] == "input" do
            {dx, dy} = vector(o["direction"])

            Enum.find_value(1..5, [], fn n ->
              q = plus(p, {dx * n, dy * n})

              case by_cell[q] do
                %{"name" => "underground-belt", "end_type" => "output", "direction" => d}
                when d == :erlang.map_get("direction", o) ->
                  [q]

                _ ->
                  nil
              end
            end)
          else
            origins = if o["name"] == "splitter", do: cells(o), else: [p]

            Enum.map(origins, &plus(&1, vector(o["direction"])))
            |> Enum.filter(&Map.has_key?(by_cell, &1))
          end

        {p, next}
      end)

    graph =
      Enum.reduce(objects, graph, fn o, g ->
        if o["name"] in ["inserter", "long-handed-inserter", "burner-inserter"] do
          {dx, dy} = vector(o["direction"])
          reach = if o["name"] == "long-handed-inserter", do: 2, else: 1
          pick = plus(point(o), {dx * reach, dy * reach})
          drop = plus(point(o), {-dx * reach, -dy * reach})

          if Map.has_key?(by_cell, pick) and Map.has_key?(by_cell, drop),
            do: Map.update!(g, pick, &[drop | &1]),
            else: g
        else
          g
        end
      end)

    {graph, by_cell}
  end

  defp reachable([], _, seen), do: seen

  defp reachable([p | rest], g, seen) do
    if MapSet.member?(seen, p),
      do: reachable(rest, g, seen),
      else: reachable(Map.get(g, p, []) ++ rest, g, MapSet.put(seen, p))
  end

  test "audited additions preserve nonoverlapping, correctly aligned footprints" do
    {l, objects} = layout()

    assert l["base_sha256"] ==
             Base.encode16(:crypto.hash(:sha256, File.read!(@base)), case: :lower)

    for {a, i} <- Enum.with_index(objects) do
      {w, h} = dims(a)
      assert Integer.mod(a["x2"], 2) == Integer.mod(w, 2)
      assert Integer.mod(a["y2"], 2) == Integer.mod(h, 2)

      for b <- Enum.take(objects, i) do
        {ww, hh} = dims(b)

        refute abs(a["x2"] - b["x2"]) < w + ww and abs(a["y2"] - b["y2"]) < h + hh,
               "overlap #{inspect(a)} / #{inspect(b)}"
      end
    end
  end

  test "ammunition can reach every guard pickup; loader drops fall inside the intended turret" do
    {l, objects} = layout()
    {g, cells} = graph(objects)
    reached = reachable([{111, -55}], g, MapSet.new())
    assert length(l["guard_loaders"]) == 10

    for loader <- l["guard_loaders"] do
      assert MapSet.member?(reached, point(loader["pickup"])), "unreachable #{loader["role"]}"
      o = Enum.find(objects, &(key(&1) == key(loader)))
      assert o
      {dx, dy} = vector(o["direction"])
      reach = if o["name"] == "long-handed-inserter", do: 2, else: 1
      assert plus(point(o), {dx * reach, dy * reach}) == point(loader["pickup"])
      {x, y} = plus(point(o), {-dx * reach, -dy * reach})
      assert abs(x - loader["guard"]["x2"]) < 2 and abs(y - loader["guard"]["y2"]) < 2
      assert cells[point(loader["pickup"])]
    end
  end

  test "coal reaches all six copper fuel pickups and all three copper outputs reach the bus sink" do
    {_, objects} = layout()
    {g, _} = graph(objects)
    fuel = reachable([{-5, -59}], g, MapSet.new())
    for y <- [5, 9, 13], do: assert(MapSet.member?(fuel, {-141, y}))
    for y <- [3, 7, 11], do: assert(MapSet.member?(fuel, {-123, y}))

    for y <- [5, 9, 13] do
      assert MapSet.member?(reachable([{-125, y}], g, MapSet.new()), {105, -13})
    end

    for o <-
          Enum.filter(objects, &(&1["name"] == "underground-belt" and &1["end_type"] == "input")) do
      assert length(g[point(o)]) == 1, "unpaired #{inspect(o)}"
    end
  end

  test "explicit power wires remain within normal small-pole reach" do
    {l, objects} = layout()
    poles = MapSet.new(Enum.filter(objects, &(&1["name"] == "small-electric-pole")), &point/1)

    for w <- l["wires"] do
      assert MapSet.member?(poles, point(w["from"]))
      assert MapSet.member?(poles, point(w["to"]))
      {x, y} = point(w["from"])
      {xx, yy} = point(w["to"])
      assert :math.pow(x - xx, 2) + :math.pow(y - yy, 2) <= 225
    end
  end
end
