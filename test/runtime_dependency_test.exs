defmodule FactorioControl.RuntimeDependencyTest do
  use ExUnit.Case, async: false
  alias FactorioControl.{Eyg, Eyg.Worker}

  @package Path.expand("../node_modules/@kek/eyg-json-bridge", __DIR__)
  @worker Path.join(@package, "node/worker.mjs")
  @scenario Path.expand("../scenarios/simulation.eyg", __DIR__)

  setup do
    previous = System.get_env("EYG_WORKER")
    System.delete_env("EYG_WORKER")

    on_exit(fn ->
      if previous,
        do: System.put_env("EYG_WORKER", previous),
        else: System.delete_env("EYG_WORKER")
    end)
  end

  test "default resolves the installed public package independently of the working directory" do
    assert Worker.path() == @worker
    assert File.regular?(@worker)

    package = JSON.decode!(File.read!(Path.join(@package, "package.json")))
    dependency = JSON.decode!(File.read!(Path.expand("../package.json", __DIR__)))
    assert package["name"] == "@kek/eyg-json-bridge"
    assert package["exports"]["./worker"] == "./node/worker.mjs"

    assert String.ends_with?(
             dependency["dependencies"]["@kek/eyg-json-bridge"],
             "/v#{package["version"]}/kek-eyg-json-bridge-#{package["version"]}.tgz"
           )

    File.cd!(__DIR__, fn -> assert Worker.path() == @worker end)
  end

  defp count_contract do
    %{
      "ReadCount" => %{
        argument: %{kind: "record", fields: %{}},
        result: %{kind: "integer"}
      }
    }
  end

  @read_count "match perform ReadCount({}) { Ok(n) -> {n} Error(_) -> {99} }"

  test "bridge retains sequential v1 request/reply frames and catchable host errors" do
    for {reply, expected} <- [{{:ok, 7}, 7}, {{:error, "denied"}, 99}] do
      assert {:ok, %{"ok" => true, "value" => ^expected}, trace} =
               Worker.run(@read_count, count_contract(), fn "ReadCount", %{} -> reply end,
                 timeout: 5000
               )

      assert [
               %{"version" => 1, "type" => "effect-request", "id" => 1},
               %{"version" => 1, "type" => "effect-response", "id" => 1},
               %{"version" => 1, "type" => "result", "ok" => true}
             ] = trace
    end
  end

  test "invalid typed replies are fatal rather than resuming the Error branch" do
    for value <- ["7", %{}, 9_007_199_254_740_992] do
      assert {:error, {:worker_protocol, %{"version" => 1, "type" => "error", "error" => error}},
              _} =
               Worker.run(@read_count, count_contract(), fn "ReadCount", %{} -> {:ok, value} end,
                 timeout: 5000
               )

      assert is_binary(error) and error != ""
    end
  end

  test "bridge still rejects extra fields in exact record replies" do
    contracts = %{
      "ReadCount" => %{
        argument: %{kind: "record", fields: %{}},
        result: %{kind: "record", fields: %{count: %{kind: "integer"}}}
      }
    }

    assert {:error,
            {:worker_protocol,
             %{"version" => 1, "type" => "error", "error" => "Expected exact record"}},
            _} =
             Worker.run(
               "match perform ReadCount({}) { Ok(n) -> {n.count} Error(_) -> {99} }",
               contracts,
               fn "ReadCount", %{} -> {:ok, %{count: 7, extra: true}} end,
               timeout: 5000
             )
  end

  test "bridge enforces the effect budget before a second host call" do
    assert {:ok, %{"ok" => false, "error" => error}, trace} =
             Worker.run(
               "let _ = perform ReadCount({})\n" <> @read_count,
               count_contract(),
               fn "ReadCount", %{} -> {:ok, 7} end,
               max_effects: 1,
               timeout: 5000
             )

    assert error =~ "effect"
    assert Enum.count(trace, &match?(%{"type" => "effect-request"}, &1)) == 1
  end

  test "explicit worker overrides environment, which overrides the installed package" do
    System.put_env("EYG_WORKER", "environment-worker.mjs")
    assert Worker.path() == Path.expand("environment-worker.mjs")
    assert Worker.path(worker: "explicit-worker.mjs") == Path.expand("explicit-worker.mjs")
    assert Worker.path(worker: nil) == Path.expand("environment-worker.mjs")
  end

  test "invalid worker configuration is rejected rather than silently ignored" do
    for path <- ["", 123] do
      assert_raise ArgumentError, "worker must be a nonempty path", fn ->
        Worker.path(worker: path)
      end
    end

    System.put_env("EYG_WORKER", "")
    assert_raise ArgumentError, "worker must be a nonempty path", fn -> Worker.path() end
  end

  test "the real runtime evaluates without a worker override or game access" do
    assert {:ok, %{"ok" => true, "value" => 42}, trace} =
             Eyg.run(nil, "!int_add(20,22)",
               effects: [],
               timeout: 5000,
               call: fn _, _ -> flunk("pure evaluation must not call the game") end
             )

    assert Enum.any?(trace, &match?(%{"type" => "result", "ok" => true}, &1))
  end

  test "missing worker has actionable errors before evaluation or connecting to the game" do
    missing = Path.join(System.tmp_dir!(), "absent-eyg-#{System.unique_integer([:positive])}.mjs")

    assert_raise ArgumentError, ~r/npm ci --ignore-scripts/, fn ->
      Worker.run("1", %{}, fn _, _ -> flunk("no handler call") end, worker: missing)
    end

    assert_raise Mix.Error, ~r/npm ci --ignore-scripts/, fn ->
      Mix.Tasks.Factorio.Eyg.run(["--worker", missing, @scenario])
    end
  end
end
