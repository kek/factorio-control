defmodule FactorioControl.Eyg.MemoryTest do
  use ExUnit.Case, async: true
  alias FactorioControl.{Eyg, Eyg.Memory, Eyg.Adapter}

  setup do
    root = Path.join(System.tmp_dir!(), "eyg-notes-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp run(code, root) do
    Eyg.run(nil, code,
      effects: Memory.effects(),
      memory_root: root,
      call: fn _, _ -> flunk("notes must not dispatch to the game") end
    )
  end

  test "typed checkpoint persists across runs with no game dispatch", %{root: root} do
    code =
      ~s|match perform SaveCheckpoint({goal:"robots",milestones:"power",verified:"iron",pending:"oil",hazards:"SE nest",evidence:"trace abc",tick:42}) {Ok(s)->{{id:s.id}} Error(e)->{{id:e}}}|

    assert {:ok, %{"ok" => true, "value" => %{"id" => id}}, trace} = run(code, root)
    assert String.starts_with?(id, "checkpoint-")
    assert Enum.any?(trace, &(&1[:type] == "effect-response" or &1["type"] == "effect-response"))

    assert {:ok, %{"value" => %{"notes" => [note]}}, _} =
             run(
               ~s|match perform ReadNotes({kind:"checkpoint",limit:1}) {Ok(s)->{{notes:s.notes}} Error(_)->{{notes:[]}}}|,
               root
             )

    assert JSON.decode!(note["contents_json"])["goal"] == "robots"
    assert File.stat!(Path.join(root, id <> ".json")).mode |> Bitwise.band(0o777) == 0o600
  end

  test "adapter forwards world storage and proposals use typed host effects", %{root: root} do
    config = %{
      host: "localhost",
      port: 27015,
      password: "test",
      bot: "default",
      artifact_root: Path.join(root, "artifacts"),
      memory_root: Path.join(root, "notes")
    }

    runner = fn code, _, opts ->
      assert opts[:memory_root] == config.memory_root
      Eyg.run(nil, code, Keyword.put(opts, :call, fn _, _ -> flunk("no game access") end))
    end

    code =
      ~s|match perform ProposeLesson({title:"inventories",lesson:"inspect first",evidence:"receipt abc"}) {Ok(s)->{{success:True({}),id:s.id,error:""}} Error(e)->{{success:False({}),id:"",error:e}}}|

    assert %{success: true, value: %{"id" => id}, artifact_dir: dir} =
             Adapter.execute(%{"program" => code}, config, runner)

    assert File.exists?(Path.join(config.memory_root, id <> ".json"))
    assert File.read!(Path.join(dir, "trace.jsonl")) =~ "ProposeLesson"
  end

  test "lesson proposals append without modifying authoritative files", %{root: root} do
    assert {:ok, %{"id" => a}} =
             Memory.handle(
               "ProposeLesson",
               %{
                 "title" => "transfer",
                 "lesson" => "use main for chests",
                 "evidence" => "receipt"
               },
               root
             )

    assert {:ok, %{"id" => b}} =
             Memory.handle(
               "ProposeLesson",
               %{"title" => "transfer", "lesson" => "verify", "evidence" => "receipt2"},
               root
             )

    refute a == b
    assert length(File.ls!(root)) == 2

    assert {:ok, %{"notes" => [_]}} =
             Memory.handle("ReadNotes", %{"kind" => "lesson", "limit" => 1}, root)
  end

  test "disabled and ungranted notes cannot write", %{root: root} do
    assert {:error, _} = Memory.handle("ReadNotes", %{}, nil)
    refute File.exists?(root)
    refute "SaveCheckpoint" in Eyg.default_effects()
    assert "SaveCheckpoint" in Adapter.effects()

    assert {:ok, %{"ok" => false}, _} =
             Eyg.run(nil, "perform ReadNotes({kind:\"checkpoint\",limit:1})", effects: [])
  end

  test "rejects oversize, traversal, excess reads and symlink notes", %{root: root} do
    assert {:error, _} =
             Memory.handle("ProposeLesson", %{"title" => String.duplicate("x", 1501)}, root)

    assert {:error, _} = Memory.handle("ReadNotes", %{"kind" => "../secret", "limit" => 1}, root)
    assert {:error, _} = Memory.handle("ReadNotes", %{"kind" => "checkpoint", "limit" => 2}, root)

    File.ln_s!(
      "/etc/passwd",
      Path.join(root, "checkpoint-00000000000000000001-#{String.duplicate("a", 32)}.json")
    )

    assert {:error, _} = Memory.handle("ReadNotes", %{"kind" => "checkpoint", "limit" => 1}, root)
  end

  test "quota refuses additional notes", %{root: root} do
    File.mkdir_p!(root)

    for n <- 1..200 do
      File.write!(
        Path.join(
          root,
          "lesson-#{String.pad_leading(to_string(n), 20, "0")}-#{String.duplicate("a", 32)}.json"
        ),
        "{}"
      )
    end

    assert {:error, "Note quota" <> _} = Memory.handle("ProposeLesson", %{"title" => "x"}, root)
    assert length(File.ls!(root)) == 200
  end
end
