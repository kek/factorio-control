defmodule FactorioControl.EvaluatorTest do
  use ExUnit.Case, async: true
  alias FactorioControl.{Eyg, Eyg.Evaluator}

  # Integration with the bridge's native BEAM adapter. The adapter's own tests
  # cover cancellation, owner death, late replies and deadlines while waiting.

  @count %{"ReadCount" => %{argument: %{kind: "record", fields: %{}}, result: %{kind: "integer"}}}
  @read_count "match perform ReadCount({}) { Ok(n) -> {n} Error(_) -> {99} }"

  defp run(code, contracts, handler, opts \\ []),
    do: Evaluator.run(code, contracts, handler, Keyword.merge([timeout: 5000], opts))

  defp no_call, do: fn _, _ -> flunk("no host call") end

  test "the bridge adapter and upstream EYG packages are compiled into this VM" do
    for app <- [:eyg_json_bridge, :eyg_parser, :eyg_analysis, :eyg_interpreter] do
      assert Application.spec(app, :vsn), "#{app} is not loaded; run mix deps.get"
    end

    assert Code.ensure_loaded?(:eyg_json_bridge_beam)

    assert {:ok, %{"ok" => true, "value" => 42}, [%{"type" => "result", "ok" => true}]} =
             Eyg.run(nil, "!int_add(20,22)", effects: [], timeout: 5000, call: no_call())
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

  test "replies that do not match the contract stop the run instead of resuming Error" do
    for value <- ["7", %{}, 9_007_199_254_740_992, 7.0, nil] do
      assert {:error, {:evaluator, "Invalid typed effect response"}, _} =
               run(@read_count, @count, fn "ReadCount", %{} -> {:ok, value} end)
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

    assert {:error, {:evaluator, "Invalid typed effect response"}, _} =
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

  test "the effect budget ends the run before a second host call" do
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
    assert {:ok, %{"ok" => false, "error" => "parse: " <> _}, _} =
             run("let = ", @count, no_call())

    for code <- [~s|perform ReadCount({extra: 1})|, ~s|perform Teleport({})|] do
      assert {:ok, %{"ok" => false, "error" => "type check failed" <> _}, _} =
               run(code, @count, no_call())
    end

    assert {:ok, %{"ok" => false, "error" => "imports/references denied"}, _} =
             run("@std:1", @count, no_call())
  end

  test "BEAM bignums are allowed in between but results stay in the safe integer range" do
    assert {:ok, %{"ok" => true, "value" => 1}, _} =
             run("!int_subtract(!int_add(9007199254740991, 1), 9007199254740991)", %{}, no_call())

    assert {:ok, %{"ok" => false, "error" => "result integer exceeds" <> _}, _} =
             run("!int_add(9007199254740991, 1)", %{}, no_call())
  end

  test "effect arguments outside the safe integer range never reach the host" do
    contracts = %{"Put" => %{argument: %{kind: "integer"}, result: %{kind: "integer"}}}

    assert {result, _, trace} =
             run("perform Put(!int_add(9007199254740991, 1))", contracts, no_call())

    assert result in [:ok, :error]
    refute Enum.any?(trace, &match?(%{"type" => "effect-request"}, &1))
  end

  test "program inputs are bound as an EYG literal and checked" do
    assert {:ok, %{"value" => %{"n" => 3, "ok" => true, "xs" => ["a"]}}, _} =
             run("input", %{}, no_call(), inputs: %{"n" => 3, "ok" => true, "xs" => ["a"]})

    for inputs <- [%{"n" => 1.5}, %{"n" => nil}, %{"Bad" => 1}] do
      assert {:error, {:evaluator, reason}, []} =
               run("input", %{}, no_call(), inputs: inputs)

      assert is_binary(reason)
    end
  end

  test "invalid host contracts stop the run before evaluation" do
    for contracts <- [
          %{"lower" => %{argument: %{kind: "integer"}, result: %{kind: "integer"}}},
          %{"Float" => %{argument: %{kind: "float"}, result: %{kind: "integer"}}},
          %{"Extra" => %{argument: %{kind: "integer", x: 1}, result: %{kind: "integer"}}}
        ] do
      assert {:error, {:evaluator, "Invalid effect contracts" <> _}, []} =
               run("1", contracts, no_call())
    end
  end

  test "an evaluation that exhausts its heap is stopped as a host failure" do
    grow = "let grow = !fix((self, xs) -> { self([1, ..xs]) })\ngrow([])"

    assert {:error, {:evaluator, _}, []} =
             run(grow, %{}, no_call(), timeout: 30_000, max_heap_bytes: 8 * 1024 * 1024)
  end

  test "host limits are validated before starting the adapter" do
    for opts <- [[timeout: 300_001], [max_effects: 101], [max_heap_bytes: 1024]] do
      assert_raise ArgumentError, fn -> run("1", %{}, no_call(), opts) end
    end
  end

  test "no adapter messages are left in the caller's mailbox" do
    assert {:ok, _, _} = run(@read_count, @count, fn "ReadCount", %{} -> {:ok, 7} end)
    refute_received {:eyg_json_bridge, _, _}
  end
end
