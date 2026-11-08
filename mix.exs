defmodule FactorioControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :factorio_control,
      version: "0.1.0",
      elixir: "~> 1.18",
      # The EYG bridge and upstream EYG packages are Gleam source; mix_gleam
      # compiles them to BEAM modules with the Gleam compiler.
      archives: [mix_gleam: "~> 0.6"],
      aliases: [
        "deps.get": [&serial_hex_fetch/1, "deps.get", "gleam.deps.get"]
      ],
      prune_code_paths: false,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      # Native BEAM adapter :eyg_json_bridge_beam (guardian/evaluator processes).
      {:eyg_json_bridge, git: "https://github.com/kek/eyg-json-bridge.git", tag: "v0.3.0"},
      # The bridge's pins, declared here too so a fresh checkout resolves them in
      # one deps.get (mix_gleam only adds the git dependency's mix.exs afterwards).
      {:eyg_parser, "0.5.2"},
      {:eyg_analysis, "3.0.1"},
      {:eyg_interpreter, "9.0.0"}
    ]
  end

  # Parallel Hex fetches race with mix_gleam's dependency rewriting and can leave
  # a package half extracted, so fetch one package at a time.
  defp serial_hex_fetch(_args) do
    if System.get_env("HEX_HTTP_CONCURRENCY") in [nil, ""],
      do: System.put_env("HEX_HTTP_CONCURRENCY", "1")
  end
end
