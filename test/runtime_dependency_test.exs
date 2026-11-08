defmodule FactorioControl.RuntimeDependencyTest do
  use ExUnit.Case, async: false
  alias FactorioControl.{Eyg, Eyg.Worker}

  @package Path.expand("../node_modules/@kek/eyg-runtime", __DIR__)
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
    assert package["name"] == "@kek/eyg-runtime"

    assert String.ends_with?(
             dependency["dependencies"]["@kek/eyg-runtime"],
             "/v#{package["version"]}/kek-eyg-runtime-#{package["version"]}.tgz"
           )

    File.cd!(__DIR__, fn -> assert Worker.path() == @worker end)
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
