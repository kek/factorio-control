defmodule FactorioControl.TestHeadless do
  @moduledoc false
  @scenario "factorio-control-native-tests/integration"
  @token "factorio-control-native-tests/v1"

  # Preparation has no process/network effects. Everything writable is created in
  # a new exclusive directory; neither the playing save nor installed mods are used.
  def prepare(project, binary) do
    project = Path.expand(project)
    binary = Path.expand(binary)
    data = Path.expand("../../data", Path.dirname(binary))

    unless File.regular?(binary) and File.dir?(Path.join(data, "quality")) and
             File.dir?(Path.join(data, "recycler")) do
      raise "Install the Factorio 2.1.24 headless distribution with quality/recycler, or set FACTORIO_HEADLESS_BINARY to its real executable"
    end

    base = Path.join(project, "tmp")
    File.mkdir_p!(base)

    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    artifacts = Path.join(base, "headless-" <> id)
    File.mkdir!(artifacts)
    # Factorio copies temporary scenario scripts with restrictive permissions.
    # Use OS-local scratch space, not a shared/FUSE project filesystem; retain
    # source snapshots in the project after the owned process has exited.
    directory = Path.join(System.tmp_dir!(), "factorio-control-native-" <> id)
    File.mkdir!(directory)
    mods = Path.join(directory, "mods")
    File.mkdir!(mods)
    File.cp_r!(Path.join(project, "mods/factorio-control"), Path.join(mods, "factorio-control"))

    File.cp_r!(
      Path.join(project, "test/fixtures/headless/factorio-control-native-tests"),
      Path.join(mods, "factorio-control-native-tests")
    )

    mod_list =
      for {name, enabled} <- [
            {"base", true},
            {"recycler", true},
            {"quality", true},
            {"space-age", false},
            {"elevated-rails", false},
            {"factorio-control", true},
            {"factorio-control-native-tests", true}
          ],
          do: %{name: name, enabled: enabled}

    File.write!(Path.join(mods, "mod-list.json"), JSON.encode!(%{mods: mod_list}))
    config = Path.join(directory, "config.ini")

    if String.contains?(data <> directory, ["\n", "\r"]),
      do: raise("INI paths cannot contain newlines")

    File.write!(config, """
    [path]
    read-data=#{data}
    write-data=#{directory}
    [other]
    check-updates=false
    crash-log-upload-enabled=false
    """)

    args = [
      "--config",
      config,
      "--mod-directory",
      mods,
      "--test-scenario",
      @scenario,
      "--test-arg",
      @token,
      "--test-ticks",
      "600"
    ]

    manifest = %{
      binary: binary,
      directory: directory,
      artifacts: artifacts,
      args: args,
      scenario: @scenario,
      source_sha256: source_hashes(mods),
      mode: "offline-test-scenario",
      results: "script-output/native-results.json"
    }

    File.write!(Path.join(directory, "manifest.json"), JSON.encode!(manifest))
    File.write!(Path.join(artifacts, "manifest.json"), JSON.encode!(manifest))
    manifest
  end

  defp source_hashes(mods) do
    for path <- Path.wildcard(Path.join(mods, "**/*")), File.regular?(path), into: %{} do
      {Path.relative_to(path, mods),
       Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)}
    end
  end

  def collect(run) do
    File.cp_r!(run.directory, run.artifacts)
    run.artifacts
  end

  def read_json!(path), do: path |> read_bounded!() |> JSON.decode!()

  def read_jsonl!(path),
    do: path |> read_bounded!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  defp read_bounded!(path) do
    if File.stat!(path).size > 1_048_576, do: raise("Oversized native test artifact: #{path}")
    File.read!(path)
  end
end
