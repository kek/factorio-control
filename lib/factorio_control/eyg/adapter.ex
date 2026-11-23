defmodule FactorioControl.Eyg.Adapter do
  @moduledoc """
  Deterministic single-program gameplay boundary. Configuration belongs to the
  operator; requests cannot choose grants, endpoints, actors, paths or commands.
  No dependency installation, lifecycle operation or retry occurs here.
  """
  alias FactorioControl.{Bot, Eyg, Rcon}

  # Deliberately enumerated: adding a host effect never silently grants it here.
  @effects ~w(InspectEquipment Equip DescribeEffect Inspect InspectBot InspectEntity InspectResources InspectAction
    InspectSimulation InspectRecipe InspectArea InspectTransport InspectWater
    InspectTechnology InspectMachine Craft WalkTo Mine Rotate Build Transfer
    TransferQuality Wait Stop Research SetChestLimit BuildUnderground SetRecipe
    ConnectPower MineObject HandCraft ReadNotes SaveCheckpoint ProposeLesson)
  @source_limit 48_000

  def effects(config \\ %{}) do
    if Map.get(config, :allow_respawn) == true, do: @effects ++ ["SpawnBot"], else: @effects
  end

  def execute(request, config, runner \\ &live/3) do
    with :ok <- validate(request),
         :ok <- validate_config(config) do
      execute_program(request["program"], config, runner)
    else
      {:error, error} -> response(false, error, nil, nil, false)
    end
  end

  defp validate(%{"program" => program} = request)
       when map_size(request) == 1 and is_binary(program) and
              byte_size(program) in 1..@source_limit do
    if String.valid?(program), do: :ok, else: {:error, "program must be UTF-8"}
  end

  defp validate(_),
    do: {:error, "Expected only program: a nonempty UTF-8 string, at most 48000 bytes"}

  defp validate_config(config) do
    Bot.validate_name!(config.bot)

    if is_binary(config.host) and config.host != "" and is_integer(config.port) and
         config.port in 1..65_535 and is_binary(config.password) and config.password != "" and
         is_binary(config.artifact_root),
       do: :ok,
       else: {:error, "Invalid operator configuration"}
  rescue
    _ -> {:error, "Invalid operator configuration"}
  end

  defp execute_program(code, config, runner) do
    # A fresh, private directory makes source and trace names host-owned, with no
    # model path interpolation. The root must be an operator-controlled directory.
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    dir = Path.join(config.artifact_root, id)
    File.mkdir_p!(config.artifact_root)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    File.write!(Path.join(dir, "program.eyg"), code, [:exclusive])
    {:ok, file} = File.open(Path.join(dir, "trace.jsonl"), [:write, :exclusive, :binary])

    trace = fn event ->
      :ok = IO.binwrite(file, JSON.encode!(event) <> "\n")
      :ok = :file.sync(file)
    end

    try do
      trace.(%{
        type: "start",
        source_sha256: Base.encode16(:crypto.hash(:sha256, code), case: :lower),
        bot: config.bot,
        effects: effects(config),
        timeout: 300_000,
        max_effects: 100
      })

      opts = [
        effects: effects(config),
        bot: config.bot,
        timeout: 300_000,
        max_effects: 100,
        trace: trace,
        memory_root: Map.get(config, :memory_root)
      ]

      result =
        case runner.(code, config, opts) do
          {:ok, %{"ok" => true, "value" => value}, _} ->
            success = not (is_map(value) and value["success"] == false)

            response(
              success,
              if(success, do: "", else: "Program reported failure"),
              value,
              dir,
              not success
            )

          {:ok, %{"ok" => false, "error" => error}, _} ->
            response(false, error, nil, dir, true)

          {:error, _, _} ->
            response(
              false,
              "Run stopped; inspect trace and world before further mutations",
              nil,
              dir,
              true
            )
        end

      trace.(%{type: "adapter_result", result: result})
      result
    rescue
      _ ->
        result =
          response(
            false,
            "Adapter failed; inspect artifacts and world before retrying",
            nil,
            dir,
            true
          )

        trace.(%{type: "adapter_result", result: result})
        result
    after
      File.close(file)
    end
  end

  defp live(code, config, opts) do
    case Rcon.start_link(host: config.host, port: config.port, password: config.password) do
      {:ok, client} ->
        try do
          Eyg.run(client, code, opts)
        after
          Rcon.close(client)
        end

      {:error, _} ->
        {:error, :connection_failed, []}
    end
  end

  defp response(success, error, value, dir, recovery) do
    %{
      success: success,
      error: error,
      value: value,
      artifact_dir: dir,
      recovery_required: recovery
    }
  end
end
