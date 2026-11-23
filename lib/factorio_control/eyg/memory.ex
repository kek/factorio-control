defmodule FactorioControl.Eyg.Memory do
  @moduledoc "Bounded, append-only gameplay notes in an operator-selected world directory."
  @effects ~w(ReadNotes SaveCheckpoint ProposeLesson)
  def effects, do: @effects
  defp record(fields), do: %{"kind" => "record", "fields" => Map.new(fields)}
  defp text, do: %{"kind" => "string"}
  defp int, do: %{"kind" => "integer"}

  def contracts do
    checkpoint =
      record(
        goal: text(),
        milestones: text(),
        verified: text(),
        pending: text(),
        hazards: text(),
        evidence: text(),
        tick: int()
      )

    lesson = record(title: text(), lesson: text(), evidence: text())

    %{
      "SaveCheckpoint" => %{"argument" => checkpoint, "result" => record(id: text())},
      "ProposeLesson" => %{"argument" => lesson, "result" => record(id: text())},
      "ReadNotes" => %{
        "argument" => record(kind: text(), limit: int()),
        "result" =>
          record(notes: %{"kind" => "list", "items" => record(id: text(), contents_json: text())})
      }
    }
  end

  def handle(_, _, nil),
    do:
      {:error,
       "Memory disabled: operator must set FACTORIO_EYG_MEMORY_ROOT to a private directory for this world"}

  def handle(effect, args, root) do
    with :ok <- directory(root) do
      case effect do
        "ReadNotes" -> read(args, root)
        "SaveCheckpoint" -> save("checkpoint", args, root)
        "ProposeLesson" -> save("lesson", args, root)
      end
    end
  rescue
    _ -> {:error, "Note storage unavailable; inspect notes before retrying a write"}
  end

  defp directory(root) do
    File.mkdir_p!(root)

    case File.lstat!(root) do
      %{type: :directory} ->
        File.chmod!(root, 0o700)
        :ok

      _ ->
        {:error, "Memory root must be a private directory, not a symlink"}
    end
  end

  defp names(root, kind) do
    File.ls!(root)
    |> Enum.filter(&Regex.match?(~r/\A#{kind}-[0-9]{20}-[a-f0-9]{32}\.json\z/, &1))
    |> Enum.sort(:desc)
  end

  defp save(kind, args, root) do
    valid =
      Enum.all?(args, fn
        {"tick", tick} -> is_integer(tick) and tick >= 0
        {_, value} -> is_binary(value) and String.valid?(value) and byte_size(value) <= 1500
      end)

    bytes = JSON.encode!(args)

    cond do
      not valid or byte_size(bytes) > 6000 ->
        {:error,
         "Note exceeds bounds: 1500 bytes/field, 6000 bytes total; tick must be nonnegative"}

      length(names(root, kind)) >= 200 ->
        {:error, "Note quota reached (200 per kind); operator archival required"}

      true ->
        id =
          kind <>
            "-" <>
            String.pad_leading(Integer.to_string(System.system_time(:microsecond)), 20, "0") <>
            "-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

        path = Path.join(root, id <> ".json")
        {:ok, file} = File.open(path, [:write, :exclusive, :binary])

        try do
          File.chmod!(path, 0o600)
          :ok = IO.binwrite(file, bytes)
          :ok = :file.sync(file)
        after
          File.close(file)
        end

        {:ok, %{"id" => id}}
    end
  end

  defp read(%{"kind" => kind, "limit" => limit}, root)
       when kind in ["checkpoint", "lesson"] and limit in 1..1 do
    notes =
      names(root, kind)
      |> Enum.take(limit)
      |> Enum.map(fn name ->
        path = Path.join(root, name)
        %{type: :regular, size: size, links: 1} = File.lstat!(path)
        true = size <= 6000
        contents = File.read!(path)
        JSON.decode!(contents)
        %{"id" => Path.rootname(name), "contents_json" => contents}
      end)

    {:ok, %{"notes" => notes}}
  end

  defp read(_, _), do: {:error, "ReadNotes requires kind checkpoint or lesson and limit 1"}
end
