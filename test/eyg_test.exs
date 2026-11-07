defmodule FactorioControl.EygTest do
  use ExUnit.Case, async: true
  alias FactorioControl.{Eyg, Eyg.Worker}

  @worker System.get_env("EYG_WORKER") ||
            Path.expand(
              "../../config/pi/agent/extensions/eyg-action/portable-worker.mjs",
              __DIR__
            )

  defp options(extra), do: Keyword.merge([worker: @worker, timeout: 5000], extra)
  defp ok(data, tick \\ 1), do: {:ok, %{"ok" => true, "tick" => tick, "data" => data}}

  defp world(count \\ 41) do
    %{
      "inventory" => %{},
      "entities" => [
        %{
          "name" => "stone-furnace",
          "position" => %{"x" => 29, "y" => -40},
          "output" => [%{"name" => "iron-plate", "quality" => "normal", "count" => count}]
        }
      ],
      "truncated" => false
    }
  end

  test "read-only grant rejects mutation before calling the game (including cleanup)" do
    assert {:ok, %{"ok" => false, "error" => error}, _} =
             Eyg.run(
               nil,
               "perform Mine({position: {x2: 0, y2: 0}, item: \"coal\", count: 1, timeout_ticks: 60})",
               options(
                 effects: ["Inspect"],
                 call: fn _, _ -> flunk("game must not be called") end
               )
             )

    assert error =~ "type check"
  end

  test "inspection normalizes empty collections and fractional world positions" do
    call = fn :inspect, %{"radius" => 5} -> ok(world()) end

    assert {:ok, %{"ok" => true, "value" => %{"inventory" => [], "entities" => [entity]}}, _} =
             Eyg.run(
               nil,
               "match perform Inspect({radius: 5}) { Ok(x) -> {x} Error(_) -> {{tick: 0, inventory: [], entities: [], truncated: True({})}} }",
               options(call: call)
             )

    assert entity["x_milli"] == 29_000
    assert entity["output"] == [%{"name" => "iron-plate", "quality" => "normal", "count" => 41}]
  end

  test "mining converts half tiles, waits for completion and retains acceptance and terminal receipts" do
    call = fn :mine, %{"position" => %{"x" => 45.5, "y" => 17.5}, "count" => 12} ->
      ok(%{"id" => 7})
    end

    await = fn 7 -> ok(%{"id" => 7, "status" => "completed", "count" => 12}, 90) end

    code =
      "match perform Mine({position: {x2: 91, y2: 35}, item: \"coal\", count: 12, timeout_ticks: 600}) { Ok(x) -> {x.count} Error(_) -> {0} }"

    assert {:ok, %{"ok" => true, "value" => 12}, trace} =
             Eyg.run(nil, code, options(call: call, await: await))

    assert Enum.any?(trace, &match?(%{type: "game_receipt", method: "mine"}, &1))
    assert Enum.any?(trace, &match?(%{type: "action_receipt", action_id: 7}, &1))
  end

  test "unknown mutation acceptance is fatal even if program handles Error; never resubmits" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    call = fn method, _ ->
      Agent.update(calls, &[method | &1])
      if method == :walk_to, do: {:error, {:unknown_outcome, :closed}}, else: ok(%{})
    end

    code =
      "match perform WalkTo({position: {x2: 0, y2: 0}, timeout_ticks: 60}) { Ok(_) -> {1} Error(_) -> {let _ = perform Stop({})\n2} }"

    assert {:error, {:game_outcome_unconfirmed, :walk_to, _}, trace} =
             Eyg.run(nil, code, options(call: call))

    assert Agent.get(calls, &Enum.reverse/1) == [:walk_to, :stop]
    assert List.last(trace).type == "cleanup_stop"
    assert Enum.count(trace, &match?(%{"type" => "effect-request"}, &1)) == 1
  end

  test "handler timeout retains action ID and cancels once" do
    call = fn
      :walk_to, _ -> ok(%{"id" => 9})
      :stop, _ -> ok(%{})
    end

    await = fn 9 -> Process.sleep(5000) end

    assert {:error, :handler_timeout, trace} =
             Eyg.run(
               nil,
               "perform WalkTo({position: {x2: 0, y2: 0}, timeout_ticks: 60})",
               options(call: call, await: await, timeout: 250)
             )

    assert Enum.any?(
             trace,
             &match?(%{type: "game_receipt", result: %{response: %{"data" => %{"id" => 9}}}}, &1)
           )

    assert List.last(trace).type == "cleanup_stop"
  end

  test "a terminal receipt for a different action cannot confirm completion" do
    call = fn
      :walk_to, _ -> ok(%{"id" => 9})
      :stop, _ -> ok(%{})
    end

    await = fn 9 -> ok(%{"id" => 10, "status" => "completed"}) end

    assert {:error, {:action_unconfirmed, 9, _}, trace} =
             Eyg.run(
               nil,
               "perform WalkTo({position: {x2: 0, y2: 0}, timeout_ticks: 60})",
               options(call: call, await: await)
             )

    assert List.last(trace).type == "cleanup_stop"
  end

  test "invalid resource bounds are ordinary errors before any game request" do
    assert {:error, _} =
             Eyg.handle(
               "Mine",
               %{
                 "position" => %{"x2" => 0, "y2" => 0},
                 "item" => "coal",
                 "count" => 1001,
                 "timeout_ticks" => 60
               },
               fn _, _ -> flunk("no call") end,
               nil
             )

    assert {:error, _} =
             Eyg.handle(
               "WalkTo",
               %{"position" => %{"x2" => 0.5, "y2" => 0}, "timeout_ticks" => 60},
               fn _, _ -> flunk("no call") end,
               nil
             )
  end

  test "build passes named cardinal directions to the mod" do
    call = fn :build, %{"direction" => "east", "position" => %{"x" => 0.5, "y" => 0.5}} ->
      ok(%{})
    end

    assert {:ok, %{"count" => 1}} =
             Eyg.handle(
               "Build",
               %{
                 "position" => %{"x2" => 1, "y2" => 1},
                 "item" => "stone-furnace",
                 "direction" => "east"
               },
               call,
               nil
             )
  end

  test "production EYG program performs the coal-to-iron workflow against a fake backend" do
    {:ok, state} = Agent.start_link(fn -> %{calls: [], inspections: 0, tick: 0} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    call = fn method, args ->
      Agent.get_and_update(state, fn state ->
        state = %{state | calls: state.calls ++ [{method, args}], tick: state.tick + 60}

        case method do
          :inspect ->
            n = state.inspections + 1
            {ok(world(if(n >= 4, do: 42, else: 41)), state.tick), %{state | inspections: n}}

          method when method in [:walk_to, :mine] ->
            {ok(%{"id" => length(state.calls)}), state}

          :transfer ->
            {ok(%{"count" => args["count"]}), state}
        end
      end)
    end

    await = fn id -> ok(%{"id" => id, "status" => "completed", "count" => 12}) end
    code = File.read!(Path.expand("../scenarios/production.eyg", __DIR__))

    assert {:ok, %{"ok" => true, "value" => %{"success" => true, "before" => 41, "after" => 42}},
            trace} = Eyg.run(nil, code, options(call: call, await: await))

    calls = Agent.get(state, & &1.calls)

    assert Enum.map(Enum.take(calls, 6), &elem(&1, 0)) == [
             :walk_to,
             :mine,
             :walk_to,
             :inspect,
             :transfer,
             :transfer
           ]

    assert Enum.count(calls, fn {method, _} -> method == :mine end) == 1
    assert length(trace) < 100
  end

  test "the evaluator does not inherit host credentials or environment" do
    path = Path.join(System.tmp_dir!(), "eyg-env-#{System.unique_integer([:positive])}.mjs")

    File.write!(
      path,
      "console.log(JSON.stringify({version:1,type:'result',ok:true,value:Object.keys(process.env).sort()}))"
    )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{"value" => ["NODE_ENV"]}, _} =
             Worker.run("1", %{}, fn _, _ -> flunk("no handler") end, worker: path, timeout: 1000)
  end

  test "host deadline kills a worker stuck in pure computation" do
    path = Path.join(System.tmp_dir!(), "eyg-busy-#{System.unique_integer([:positive])}.mjs")
    File.write!(path, "while (true) {}")
    on_exit(fn -> File.rm(path) end)
    started = System.monotonic_time(:millisecond)

    assert {:error, :run_timeout, []} =
             Worker.run("1", %{}, fn _, _ -> flunk("no handler") end, worker: path, timeout: 100)

    assert System.monotonic_time(:millisecond) - started < 2000
  end
end
