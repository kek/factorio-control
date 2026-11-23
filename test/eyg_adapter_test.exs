defmodule FactorioControl.Eyg.AdapterTest do
  use ExUnit.Case, async: true
  alias FactorioControl.{Eyg, Eyg.Adapter}

  setup do
    root = Path.join(System.tmp_dir!(), "adapter-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     config: %{
       host: "localhost",
       port: 27015,
       password: "test-secret",
       bot: "default",
       artifact_root: root
     }}
  end

  test "rejects request options before any runner or filesystem effect", %{config: config} do
    runner = fn _, _, _ -> flunk("must not execute") end

    for request <- [
          %{"program" => "{}", "effects" => ["ConfirmLuaConsole"]},
          %{"program" => "{}", "host" => "elsewhere"},
          %{"program" => "{}", "bot" => "other"},
          %{"program" => String.duplicate("a", 48_001)},
          %{},
          %{"program" => ""}
        ] do
      assert %{success: false, recovery_required: false} =
               Adapter.execute(request, config, runner)
    end

    refute File.exists?(config.artifact_root)
  end

  test "retains exclusive source and traces; grants are fixed and secret-free", %{config: config} do
    runner = fn code, actual_config, opts ->
      assert actual_config.bot == "default"
      assert opts[:effects] == Adapter.effects()
      refute "ConfirmLuaConsole" in opts[:effects]
      assert opts[:max_effects] == 100
      opts[:trace].(%{type: "fake_receipt"})
      Eyg.run(nil, code, opts)
    end

    first = Adapter.execute(%{"program" => "{success:True({})}"}, config, runner)
    second = Adapter.execute(%{"program" => "{success:True({})}"}, config, runner)
    assert first.success
    refute first.recovery_required
    refute first.artifact_dir == second.artifact_dir
    assert File.read!(Path.join(first.artifact_dir, "program.eyg")) == "{success:True({})}"
    trace = File.read!(Path.join(first.artifact_dir, "trace.jsonl"))
    refute trace =~ config.password
    assert trace =~ "fake_receipt"
    assert trace =~ "source_sha256"
    assert trace =~ "adapter_result"
  end

  test "ungranted effects and imports never reach game backend", %{config: config} do
    runner = fn code, _, opts ->
      Eyg.run(
        nil,
        code,
        Keyword.put(opts, :call, fn _, _ -> flunk("denied before game call") end)
      )
    end

    for code <- [
          "perform ConfirmLuaConsole({confirm:True({})})",
          "perform Bash({command:\"whoami\"})",
          "import \"file:///etc/passwd\""
        ] do
      assert %{success: false} = Adapter.execute(%{"program" => code}, config, runner)
    end
  end

  test "forwards typed game effects only and preserves receipts", %{config: config} do
    parent = self()

    runner = fn code, _, opts ->
      call = fn :inspect_simulation, %{} ->
        send(parent, :inspected)

        {:ok,
         %{
           "ok" => true,
           "tick" => 42,
           "data" => %{
             "speed" => 1,
             "tick_paused" => false,
             "connected_players" => 0,
             "version" => "2.1.24"
           }
         }}
      end

      Eyg.run(nil, code, Keyword.put(opts, :call, call))
    end

    result =
      Adapter.execute(
        %{
          "program" =>
            "match perform InspectSimulation({}) {Ok(s)->{{success:True({}),tick:s.tick}} Error(e)->{{success:False({}),tick:0}}}"
        },
        config,
        runner
      )

    assert result.success
    assert result.value["tick"] == 42
    assert_received :inspected
  end

  test "tool-only agent can discover schemas without a filesystem capability", %{config: config} do
    runner = fn code, _, opts ->
      Eyg.run(
        nil,
        code,
        Keyword.put(opts, :call, fn _, _ -> flunk("schema lookup is host-local") end)
      )
    end

    result =
      Adapter.execute(
        %{
          "program" =>
            "match perform DescribeEffect({name:\"Build\"}) {Ok(s)->{{schema:s.argument_json}} Error(e)->{{schema:e}}}"
        },
        config,
        runner
      )

    assert result.success

    assert JSON.decode!(result.value["schema"])["fields"]["position"]["fields"]["x2"] == %{
             "kind" => "integer"
           }
  end

  test "exact Pi tool examples typecheck and handle success and errors", %{config: config} do
    {json, 0} =
      System.cmd("node", [
        "--input-type=module",
        "-e",
        "import {programExamples} from './integrations/pi/index.js'; console.log(JSON.stringify(programExamples))"
      ])

    examples = JSON.decode!(json)

    for {name, code} <- examples, fail_backend <- [false, true] do
      runner = fn source, _, opts ->
        call = fn :inspect, %{"radius" => 0} ->
          if fail_backend do
            {:ok, %{"ok" => false, "error" => "test unavailable"}}
          else
            {:ok,
             %{
               "ok" => true,
               "tick" => 42,
               "data" => %{
                 "position" => %{"x" => 1, "y" => 2},
                 "health" => 100,
                 "surface" => "nauvis",
                 "inventory" => [],
                 "active_action" => nil
               }
             }}
          end
        end

        Eyg.run(nil, source, Keyword.put(opts, :call, call))
      end

      result = Adapter.execute(%{"program" => code}, config, runner)
      assert result.error != "type check failed (invalid type or unapproved effects)"

      if name == "inspectBot" and fail_backend do
        assert result.value["success"] == false
        assert result.value["inventory"] == []
        assert result.value["error"] != ""
      else
        assert result.success, inspect(result)
        assert result.value["success"] == true
        assert result.value["error"] == ""
      end
    end
  end

  test "failure never retries and demands recovery", %{config: config} do
    runner = fn _, _, opts ->
      opts[:trace].(%{type: "action_submission", method: "walk_to"})
      send(self(), :attempted)
      {:error, :unknown_outcome, []}
    end

    assert %{success: false, recovery_required: true} =
             Adapter.execute(%{"program" => "{}"}, config, runner)

    assert_received :attempted
    refute_received :attempted
  end
end
