defmodule Mix.Tasks.Factorio.Eyg do
  use Mix.Task
  @shortdoc "Run a typed EYG program against the existing Factorio bot"
  alias FactorioControl.{Eyg, Eyg.Worker, Rcon}

  def run(args) do
    Mix.Task.run("app.start")

    {opts, args, invalid} =
      OptionParser.parse(args,
        strict: [
          worker: :string,
          timeout: :integer,
          max_effects: :integer,
          effects: :string,
          trace: :string,
          host: :string,
          port: :integer
        ]
      )

    if invalid != [], do: Mix.raise("Unknown options: #{inspect(invalid)}")

    file =
      case args do
        [file] ->
          file

        _ ->
          Mix.raise(
            "Usage: mix factorio.eyg [--worker PATH] [--effects Inspect,WalkTo,...] [--trace PATH] FILE.eyg"
          )
      end

    worker = Worker.path(opts)

    unless File.regular?(worker),
      do:
        Mix.raise(
          "Worker does not exist: #{worker}. Run npm ci --ignore-scripts, or set EYG_WORKER / --worker."
        )

    code = File.read!(file)
    password = System.get_env("FACTORIO_RCON_PASSWORD") || Mix.raise("Set FACTORIO_RCON_PASSWORD")

    trace_path =
      opts[:trace] ||
        Path.join(System.tmp_dir!(), "factorio-eyg-#{System.system_time(:microsecond)}.jsonl")

    # Exclusive, private log: never overwrite earlier evidence or follow a leaf symlink.
    {:ok, trace_file} = File.open(trace_path, [:write, :exclusive, :binary])
    File.chmod!(trace_path, 0o600)
    Mix.shell().info("Trace: #{trace_path}")

    trace = fn event ->
      :ok = IO.binwrite(trace_file, JSON.encode!(event) <> "\n")
      :ok = :file.sync(trace_file)
    end

    run_opts =
      opts
      |> Keyword.take([:timeout, :max_effects])
      |> Keyword.merge(worker: Path.expand(worker), trace: trace)

    run_opts =
      if opts[:effects],
        do: Keyword.put(run_opts, :effects, String.split(opts[:effects], ",", trim: true)),
        else: run_opts

    trace.(%{
      type: "start",
      source_sha256: Base.encode16(:crypto.hash(:sha256, code), case: :lower),
      worker: Path.expand(worker),
      effects: Keyword.get(run_opts, :effects, Map.keys(Eyg.contracts()))
    })

    try do
      case Rcon.start_link(Keyword.merge(Keyword.take(opts, [:host, :port]), password: password)) do
        {:ok, client} ->
          try do
            case Eyg.run(client, code, run_opts) do
              {:ok, %{"ok" => true, "value" => value}, _} ->
                Mix.shell().info(JSON.encode!(value))

                if is_map(value) and value["success"] == false,
                  do: Mix.raise("Scenario reported failure; inspect trace")

              {:ok, result, _} ->
                Mix.raise("EYG evaluation failed: #{inspect(result)}")

              {:error, reason, _} ->
                Mix.raise(
                  "EYG run stopped: #{inspect(reason)}; inspect trace and game state before retrying"
                )
            end
          after
            Rcon.close(client)
          end

        {:error, reason} ->
          Mix.raise("Connection failed: #{inspect(reason)}")
      end
    after
      File.close(trace_file)
    end
  end
end
