defmodule FactorioControl.HeadlessIsolationTest do
  use ExUnit.Case, async: true
  alias FactorioControl.TestHeadless

  test "preparation uses exclusive copied mods and offline-only arguments" do
    project =
      Path.join(
        System.tmp_dir!(),
        "headless-isolation-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    on_exit(fn -> File.rm_rf!(project) end)
    binary = Path.join(project, "distribution/bin/x64/factorio")

    for dir <- [
          Path.dirname(binary),
          Path.join(project, "distribution/data/quality"),
          Path.join(project, "distribution/data/recycler"),
          Path.join(project, "mods/factorio-control"),
          Path.join(
            project,
            "test/fixtures/headless/factorio-control-native-tests/scenarios/integration"
          )
        ] do
      File.mkdir_p!(dir)
    end

    File.write!(binary, "not executed by preparation")
    File.write!(Path.join(project, "mods/factorio-control/control.lua"), "production source")

    File.write!(
      Path.join(project, "test/fixtures/headless/factorio-control-native-tests/info.json"),
      "{}"
    )

    a = TestHeadless.prepare(project, binary)
    b = TestHeadless.prepare(project, binary)

    on_exit(fn ->
      File.rm_rf!(a.directory)
      File.rm_rf!(b.directory)
    end)

    refute a.directory == b.directory
    assert String.starts_with?(a.artifacts, Path.join(project, "tmp/headless-"))
    refute String.starts_with?(a.directory, project)
    assert "--test-scenario" in a.args
    assert "--test-ticks" in a.args

    refute Enum.any?(
             a.args,
             &String.starts_with?(&1, ["--start-server", "--rcon", "--load-game"])
           )

    config = File.read!(Path.join(a.directory, "config.ini"))
    assert config =~ "write-data=#{a.directory}\n"

    assert a.source_sha256["factorio-control/control.lua"] ==
             Base.encode16(:crypto.hash(:sha256, "production source"), case: :lower)

    copied = Path.join(a.directory, "mods/factorio-control/control.lua")
    assert File.lstat!(copied).type == :regular
    File.write!(copied, "modified test copy")

    assert File.read!(Path.join(project, "mods/factorio-control/control.lua")) ==
             "production source"

    TestHeadless.collect(a)

    assert File.read!(Path.join(a.artifacts, "mods/factorio-control/control.lua")) ==
             "modified test copy"

    mod_list = TestHeadless.read_json!(Path.join(a.directory, "mods/mod-list.json"))
    assert %{"name" => "quality", "enabled" => true} in mod_list["mods"]
    assert %{"name" => "space-age", "enabled" => false} in mod_list["mods"]
  end

  test "an explicit native run fails clearly without a compatible distribution" do
    assert_raise RuntimeError, ~r/Factorio 2.1.24/, fn ->
      TestHeadless.prepare("/not-a-project", "/not-a-factorio-binary")
    end
  end
end
