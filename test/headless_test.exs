defmodule FactorioControl.HeadlessTest do
  use ExUnit.Case, async: false
  alias FactorioControl.{Eyg, Server, TestHeadless}
  @moduletag :headless
  @moduletag timeout: 180_000
  @cases ~w(transport-tiers-qualities-and-modded-prototypes transport-invalid-targets-and-bounds quality-agnostic-entity-and-machine-inspection inspection-privacy-ambiguity-and-range corpse-inspection-privacy-and-proximity exact-quality-and-legacy no-quality-substitution rare-partial-capacity partial-ammunition blueprint-metadata equipped-armor character-equipment-native-transfers damaged-stack logistic-container-inventories machine-module-transfers inventory-permission-guards dry-fluid-capable-assembler-tiers nonempty-input-output-and-modules native-progress-and-recipe-locks fluid-residue-is-preserved unsupported-and-locked-recipes fractional-tree-mining native-character-combat)

  test "offline engine invariants and captured native receipts conform to typed EYG" do
    project = Path.expand("..", __DIR__)

    binary =
      System.get_env("FACTORIO_HEADLESS_BINARY") ||
        Path.join(project, "factorio/bin/x64/factorio")

    run = TestHeadless.prepare(project, binary)
    IO.puts("Headless artifacts: #{run.artifacts}")

    # No live endpoint, password, save, script/server or multiplayer/RCON flags.
    # The same Port owner handles natural exit and failures for this one-shot run.
    {:ok, owner} =
      Server.start_link(
        executable: run.binary,
        directory: run.directory,
        args: run.args,
        password: "unused-offline-test-password",
        shutdown_timeout: 10_000
      )

    try do
      exit_result = Server.await_exit(owner, 120_000)
      status = Server.status(owner)
      File.write!(Path.join(run.directory, "port-output.log"), status.output)
      if status.state == :exited, do: TestHeadless.collect(run)

      assert exit_result == {:ok, 0},
             "Native process failed: #{inspect(exit_result)}\n#{status.output}"

      result =
        TestHeadless.read_json!(Path.join(run.artifacts, "script-output/native-results.json"))

      assert result["suite"] == "factorio-control-native-tests/v1"
      assert result["passed"], inspect(result)
      assert result["completed"] == @cases
      assert status.output =~ "FACTORIO_CONTROL_NATIVE_RESULT"

      receipts =
        TestHeadless.read_jsonl!(Path.join(run.artifacts, "script-output/native-effects.jsonl"))

      assert length(receipts) in 1..256

      replayed =
        Enum.with_index(receipts, 1)
        |> Enum.count(fn {receipt, index} -> replay(receipt, index, run.artifacts) end)

      expected = Enum.count(receipts, &(&1["request"]["method"] != "spawn"))
      assert replayed == expected, "every recorded non-setup request must have typed EYG coverage"
      assert replayed > 30

      mining =
        TestHeadless.read_jsonl!(Path.join(run.artifacts, "script-output/native-mining.jsonl"))

      assert length(mining) == 2

      for {event, index} <- Enum.with_index(mining, 1) do
        args = event["request"]["args"]
        position = args["position"]

        input =
          Map.put(args, "position", %{
            "x2" => round(position["x"] * 2),
            "y2" => round(position["y"] * 2)
          })

        source =
          "match perform MineObject(input.request) {Ok(s)->{{count:s.count,error:\"\"}} Error(e)->{{count:0,error:e}}}"

        call = fn :mine_object, received ->
          assert received == args
          {:ok, event["response"]}
        end

        await = fn id ->
          assert id == event["terminal"]["data"]["id"]
          {:ok, event["terminal"]}
        end

        assert {:ok, %{"value" => %{"count" => 1, "error" => ""}}, trace} =
                 Eyg.run(nil, source,
                   effects: ["MineObject"],
                   inputs: %{"request" => input},
                   call: call,
                   await: await
                 )

        prefix = Path.join(run.artifacts, "mining-#{index}")
        File.write!(prefix <> ".eyg", Eyg.Evaluator.program(source, %{"request" => input}))
        File.write!(prefix <> ".jsonl", Enum.map_join(trace, "\n", &JSON.encode!/1) <> "\n")
      end

      combat =
        TestHeadless.read_json!(Path.join(run.artifacts, "script-output/native-combat.json"))

      attack_source =
        "match perform Attack(input.request) {Ok(s)->{{rounds:s.rounds_used,gone:s.target_gone,error:\"\"}} Error(e)->{{rounds:0,gone:False({}),error:e}}}"

      assert {:ok, %{"value" => %{"rounds" => rounds, "gone" => true, "error" => ""}}, trace} =
               Eyg.run(nil, attack_source,
                 effects: ["Attack"],
                 inputs: %{"request" => combat["request"]["args"]},
                 call: fn :attack, args ->
                   assert args == combat["request"]["args"]
                   {:ok, combat["response"]}
                 end,
                 await: fn id ->
                   assert id == combat["terminal"]["data"]["id"]
                   {:ok, combat["terminal"]}
                 end
               )

      assert rounds > 0

      File.write!(
        Path.join(run.artifacts, "combat.eyg"),
        Eyg.Evaluator.program(attack_source, %{"request" => combat["request"]["args"]})
      )

      File.write!(
        Path.join(run.artifacts, "combat.jsonl"),
        Enum.map_join(trace, "\n", &JSON.encode!/1) <> "\n"
      )

      assert {:ok, %{"value" => %{"enemies" => enemies}}, _} =
               Eyg.run(
                 nil,
                 "match perform InspectCombat({radius:16}) {Ok(s)->{{enemies:s.enemies}} Error(_)->{{enemies:[]}}}",
                 effects: ["InspectCombat"],
                 call: fn :inspect_combat, %{"radius" => 16} -> {:ok, combat["observation"]} end
               )

      assert Enum.any?(enemies, &(&1["unit_number"] == combat["request"]["args"]["unit_number"]))

      File.write!(
        Path.join(run.artifacts, "verification.json"),
        JSON.encode!(%{
          native_cases: result["completed"],
          native_passed: true,
          typed_receipts_replayed: replayed,
          note: "Offline engine tests plus typed EYG receipt replay, not a real-time RCON test"
        })
      )
    after
      # A timeout does not release ownership or delete evidence. Never replace an
      # uncertain process with another one or force-clean its files.
      case Server.stop(owner) do
        :ok ->
          File.write!(Path.join(run.directory, "port-output.log"), Server.status(owner).output)
          GenServer.stop(owner)
          TestHeadless.collect(run)
          File.rm_rf!(run.directory)

        error ->
          flunk(
            "Offline process did not confirm exit (#{inspect(error)}); preserve #{run.directory} and #{run.artifacts}, and confirm process exit before rerunning"
          )
      end
    end
  end

  # Native assertions inspect actual item metadata and machine state. Replaying
  # their real receipts here additionally checks production EYG argument/result
  # contracts and error handling, without inventing an offline command bridge.
  defp replay(
         %{"request" => %{"method" => method, "args" => args}, "response" => response} = event,
         index,
         directory
       )
       when method in [
              "equip",
              "inspect_equipment",
              "transfer",
              "transfer_quality",
              "set_recipe",
              "set_chest_limit",
              "inspect_entity",
              "inspect_machine",
              "inspect_transport"
            ] do
    effect =
      %{
        "equip" => "Equip",
        "inspect_equipment" => "InspectEquipment",
        "transfer" => "Transfer",
        "transfer_quality" => "TransferQuality",
        "set_recipe" => "SetRecipe",
        "set_chest_limit" => "SetChestLimit",
        "inspect_entity" => "InspectEntity",
        "inspect_machine" => "InspectMachine",
        "inspect_transport" => "InspectTransport"
      }[method]

    position = args["position"]

    host_args =
      if position do
        Map.put(args, "position", %{
          "x2" => round(position["x"] * 2),
          "y2" => round(position["y"] * 2)
        })
      else
        args
      end

    source = TestHeadless.replay_source(effect)
    inputs = %{"request" => host_args}
    prefix = Path.join(directory, "eyg-#{String.pad_leading(to_string(index), 3, "0")}")
    File.write!(prefix <> ".eyg", Eyg.Evaluator.program(source, inputs))
    ref = make_ref()
    parent = self()

    call = fn received_method, received_args ->
      assert to_string(received_method) == method
      assert received_args == args
      send(parent, {ref, :called})
      {:ok, response}
    end

    assert {:ok, %{"ok" => true, "value" => value}, trace} =
             Eyg.run(nil, source, effects: [effect], inputs: inputs, call: call)

    File.write!(prefix <> ".jsonl", Enum.map_join(trace, "\n", &JSON.encode!/1) <> "\n")
    assert_received {^ref, :called}
    refute_received {^ref, :called}
    assert value["accepted"] == response["ok"], inspect(event)

    cond do
      not response["ok"] ->
        assert value["error"] =~ response["error"]["code"]

      method == "inspect_equipment" ->
        assert value["slots"] == response["data"]["slots"]

      method == "inspect_transport" ->
        assert value["name"] == response["data"]["name"]
        assert value["direction"] == response["data"]["direction"]

        expected =
          Enum.map(response["data"]["lanes"], fn lane ->
            items = lane["items"]

            %{
              "index" => lane["index"],
              "items" =>
                if(is_list(items),
                  do: Enum.map(items, &Map.take(&1, ["name", "quality", "count"])),
                  else: []
                )
            }
          end)

        assert value["lanes"] == expected

      method in ["inspect_entity", "inspect_machine"] ->
        assert value["name"] == response["data"]["name"]
        assert value["type"] == response["data"]["type"]
        assert value["x_milli"] == round(response["data"]["position"]["x"] * 1000)
        assert value["y_milli"] == round(response["data"]["position"]["y"] * 1000)

        for field <- ["inventory", "modules", "input", "output", "fuel"] do
          native = response["data"][field]

          expected =
            if is_list(native),
              do: Enum.map(native, &Map.take(&1, ["name", "quality", "count"])),
              else: []

          assert value[field] == expected
        end

      true ->
        expected =
          case method do
            "set_recipe" -> 0
            "set_chest_limit" -> args["slots"]
            _ -> response["data"]["count"]
          end

        assert value["count"] == expected
    end

    true
  end

  defp replay(_, _, _), do: false
end
