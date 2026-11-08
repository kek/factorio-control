defmodule FactorioControl.RefuelPipelineTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  @worker System.get_env("EYG_WORKER") ||
            Path.expand(
              "../../config/pi/agent/extensions/eyg-action/portable-worker.mjs",
              __DIR__
            )
  @root Path.expand("../scenarios/iron-pipeline/refuel", __DIR__)
  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 100, "data" => data}}

  defp phase(number, build_reply) do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)
    name = "build-belts-#{String.pad_leading(to_string(number), 2, "0")}.eyg"

    result =
      Eyg.run(nil, File.read!(Path.join(@root, name)),
        worker: @worker,
        effects: ["WalkTo", "Build"],
        call: fn method, args ->
          Agent.update(calls, &[{method, args} | &1])

          case method do
            :walk_to -> ok(%{"id" => 1})
            :build -> build_reply.()
          end
        end,
        await: fn 1 -> ok(%{"id" => 1, "status" => "completed"}) end
      )

    {result, Agent.get(calls, &Enum.reverse/1)}
  end

  test "six bounded EYG phases place exactly the audited 184-belt route" do
    actual =
      Enum.flat_map(1..6, fn number ->
        {result, calls} = phase(number, fn -> ok(%{}) end)
        assert {:ok, %{"ok" => true, "value" => %{"success" => true}}, _} = result
        assert length(calls) < 100

        for {:build, a} <- calls do
          assert a["item"] == "transport-belt"

          %{
            "x2" => round(a["position"]["x"] * 2),
            "y2" => round(a["position"]["y"] * 2),
            "direction" => a["direction"]
          }
        end
      end)

    expected = JSON.decode!(File.read!(Path.join(@root, "route.json")))["cells"]
    assert actual == expected
    assert length(actual) == 184
  end

  test "belt chain has no self-intersections and reaches all fourteen fuel pickups" do
    cells = JSON.decode!(File.read!(Path.join(@root, "route.json")))["cells"]
    coordinates = MapSet.new(cells, &{&1["x2"], &1["y2"]})
    assert MapSet.size(coordinates) == length(cells)
    deltas = %{"north" => {0, -2}, "south" => {0, 2}, "east" => {2, 0}, "west" => {-2, 0}}

    for [a, b] <- Enum.chunk_every(cells, 2, 1, :discard) do
      {dx, dy} = deltas[a["direction"]]
      assert {a["x2"] + dx, a["y2"] + dy} == {b["x2"], b["y2"]}
    end

    for pickup <- [
          {111, 37},
          {125, 37},
          {45, -85},
          {45, -81},
          {47, -77},
          {53, -85},
          {53, -81},
          {55, -77},
          {61, -85},
          {61, -81},
          {71, -77},
          {69, -85},
          {69, -81},
          {79, -77}
        ] do
      assert MapSet.member?(coordinates, pickup)
    end

    # Existing storage which the serpentine deliberately routes around.
    refute MapSet.member?(coordinates, {61, -77})
    refute MapSet.member?(coordinates, {63, -75})
  end

  test "a rejected placement halts the phase without resubmission or later placements" do
    {result, calls} =
      phase(1, fn ->
        {:ok,
         %{
           "ok" => false,
           "tick" => 100,
           "error" => %{"code" => "blocked", "message" => "fixture obstacle"}
         }}
      end)

    assert {:ok, %{"ok" => true, "value" => %{"success" => false}}, _} = result
    assert Enum.count(calls, fn {method, _} -> method == :build end) == 1
  end
end
