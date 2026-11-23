defmodule FactorioControl.EvaluatorTest do
  use ExUnit.Case, async: true
  alias FactorioControl.{Eyg, Eyg.Evaluator}

  @count %{"ReadCount" => %{argument: %{kind: "record", fields: %{}}, result: %{kind: "integer"}}}
  @read_count "match perform ReadCount({}) { Ok(n) -> {n} Error(_) -> {99} }"

  defp run(code, contracts, handler, opts \\ []),
    do: Evaluator.run(code, contracts, handler, Keyword.merge([timeout: 5000], opts))

  test "upstream EYG packages are compiled into this VM" do
    for app <- [:eyg_parser, :eyg_analysis, :eyg_interpreter] do
      assert Application.spec(app, :vsn), "#{app} is not loaded; run mix deps.get"
    end

    assert {:ok, %{"ok" => true, "value" => 42}, trace} =
             Eyg.run(nil, "!int_add(20,22)",
               effects: [],
               timeout: 5000,
               call: fn _, _ -> flunk("pure evaluation must not call the game") end
             )

    assert [%{"type" => "result", "ok" => true}] = trace
  end

  test "sequential request/reply trace and catchable host errors" do
    for {reply, expected} <- [{{:ok, 7}, 7}, {{:error, "denied"}, 99}] do
      assert {:ok, %{"ok" => true, "value" => ^expected}, trace} =
               run(@read_count, @count, fn "ReadCount", %{} -> reply end)

      assert [
               %{
                 "type" => "effect-request",
                 "id" => 1,
                 "effect" => "ReadCount",
                 "argument" => %{}
               },
               %{"type" => "effect-response", "id" => 1},
               %{"type" => "result", "ok" => true}
             ] = trace
    end
  end

  test "invalid typed replies are fatal rather than resuming the Error branch" do
    for value <- ["7", %{}, 9_007_199_254_740_992, 7.0, nil] do
      assert {:error, {:invalid_reply, message}, trace} =
               run(@read_count, @count, fn "ReadCount", %{} -> {:ok, value} end)

      assert is_binary(message)
      refute Enum.any?(trace, &match?(%{"type" => "effect-response"}, &1))
    end
  end

  test "records are exact in both directions" do
    contracts = %{
      "ReadCount" => %{
        argument: %{kind: "record", fields: %{}},
        result: %{kind: "record", fields: %{count: %{kind: "integer"}}}
      }
    }

    code = "match perform ReadCount({}) { Ok(n) -> {n.count} Error(_) -> {99} }"

    assert {:error, {:invalid_reply, "Expected exact record"}, _} =
             run(code, contracts, fn "ReadCount", %{} -> {:ok, %{count: 7, extra: true}} end)

    assert {:ok, %{"value" => 7}, _} =
             run(code, contracts, fn "ReadCount", %{} -> {:ok, %{count: 7}} end)
  end

  test "lists, booleans and nested records round-trip through contracts" do
    contracts = %{
      "Echo" => %{
        argument: %{
          kind: "record",
          fields: %{flag: %{kind: "boolean"}, xs: %{kind: "list", items: %{kind: "integer"}}}
        },
        result: %{kind: "list", items: %{kind: "record", fields: %{flag: %{kind: "boolean"}}}}
      }
    }

    handler = fn "Echo", %{"flag" => true, "xs" => [1, 2]} -> {:ok, [%{flag: false}]} end

    assert {:ok, %{"value" => [%{"flag" => false}]}, _} =
             run(
               "match perform Echo({flag: True({}), xs: [1, 2]}) { Ok(x) -> {x} Error(_) -> {[]} }",
               contracts,
               handler
             )
  end

  test "the effect budget stops the run before a second host call" do
    assert {:ok, %{"ok" => false, "error" => "effect budget exceeded"}, trace} =
             run(
               "let _ = perform ReadCount({})\n" <> @read_count,
               @count,
               fn "ReadCount", %{} -> {:ok, 7} end,
               max_effects: 1
             )

    assert Enum.count(trace, &match?(%{"type" => "effect-request"}, &1)) == 1
  end

  test "parse, type and reference failures are evaluation results, not host calls" do
    no_call = fn _, _ -> flunk("no host call") end

    assert {:ok, %{"ok" => false, "error" => "parse: " <> _}, _} = run("let = ", @count, no_call)

    assert {:ok, %{"ok" => false, "error" => "type check failed" <> _}, _} =
             run(~s|perform ReadCount({extra: 1})|, @count, no_call)

    assert {:ok, %{"ok" => false, "error" => "type check failed" <> _}, _} =
             run(~s|perform Teleport({})|, @count, no_call)

    assert {:ok, %{"ok" => false, "error" => "imports/references denied"}, _} =
             run("@std:1", @count, no_call)
  end

  test "BEAM bignums are allowed in between but results stay in the safe integer range" do
    no_call = fn _, _ -> flunk("no host call") end

    assert {:ok, %{"ok" => true, "value" => 1}, _} =
             run("!int_subtract(!int_add(9007199254740991, 1), 9007199254740991)", %{}, no_call)

    assert {:ok, %{"ok" => false, "error" => "result integer exceeds" <> _}, _} =
             run("!int_add(9007199254740991, 1)", %{}, no_call)
  end

  test "effect arguments outside the safe integer range never reach the host" do
    contracts = %{"Put" => %{argument: %{kind: "integer"}, result: %{kind: "integer"}}}

    assert {:ok, %{"ok" => false, "error" => "invalid typed effect argument"},
            [%{"type" => "result"}]} =
             run(
               "perform Put(!int_add(9007199254740991, 1))",
               contracts,
               fn _, _ -> flunk("no host call") end
             )
  end

  test "program inputs are bound as an EYG literal" do
    assert {:ok, %{"value" => %{"n" => 3, "ok" => true, "xs" => ["a"]}}, _} =
             run("input", %{}, fn _, _ -> flunk("no host call") end,
               inputs: %{"n" => 3, "ok" => true, "xs" => ["a"]}
             )

    for inputs <- [%{"n" => 1.5}, %{"n" => nil}, %{"Bad" => 1}] do
      assert_raise ArgumentError, fn -> Evaluator.program("input", inputs) end
    end
  end

  test "contract count remains bounded while accommodating gameplay recovery" do
    contracts =
      Map.new(1..64, fn n ->
        {"Effect#{n}", %{argument: %{kind: "integer"}, result: %{kind: "integer"}}}
      end)

    assert {:ok, %{"value" => 1}, _} = run("1", contracts, fn _, _ -> flunk("no host call") end)

    assert_raise ArgumentError, "invalid effect contracts", fn ->
      run("1", Map.put(contracts, "Overflow", contracts["Effect1"]), fn _, _ ->
        flunk("no host call")
      end)
    end
  end

  test "invalid host contracts are rejected before evaluation" do
    for contracts <- [
          %{"lower" => %{argument: %{kind: "integer"}, result: %{kind: "integer"}}},
          %{"Float" => %{argument: %{kind: "float"}, result: %{kind: "integer"}}},
          %{"Extra" => %{argument: %{kind: "integer", x: 1}, result: %{kind: "integer"}}}
        ] do
      assert_raise ArgumentError, "invalid effect contracts", fn ->
        run("1", contracts, fn _, _ -> flunk("no host call") end)
      end
    end
  end

  test "an evaluation that exhausts its heap is stopped as a host failure" do
    grow = "let grow = !fix((self, xs) -> { self([1, ..xs]) })\ngrow([])"

    assert {:error, :evaluator_memory_exceeded, []} =
             run(grow, %{}, fn _, _ -> flunk("no host call") end,
               timeout: 30_000,
               max_heap_bytes: 8 * 1024 * 1024
             )
  end

  test "caller death stops evaluation stuck in pure computation" do
    test = self()
    loop = "let loop = !fix((self, x) -> { self(!int_add(x, 1)) })\nloop(0)"

    caller =
      spawn(fn ->
        Evaluator.run(loop, %{}, fn _, _ -> :ok end,
          timeout: 60_000,
          trace: fn _ -> :ok end,
          test_evaluator: fn owner ->
            send(test, {:evaluator, self()})
            Process.sleep(:infinity)
            send(owner, :unreachable)
          end
        )
      end)

    assert_receive {:evaluator, evaluator}, 1000
    ref = Process.monitor(evaluator)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^evaluator, :killed}, 1000
  end
end
