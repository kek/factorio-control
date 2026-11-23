defmodule FactorioControl.Bot do
  @moduledoc "JSON adapter to the mod's constrained bot interface."
  alias FactorioControl.Rcon

  @methods ~w(inspect_equipment equip spawn inspect inspect_entity inspect_simulation inspect_recipe walk_to mine craft stop action build rotate transfer transfer_quality inspect_area inspect_water inspect_technology inspect_machine inspect_transport research set_recipe connect_power mine_object hand_craft set_chest_limit build_underground)

  @doc "Validate a bot selector before any request is sent."
  def validate_name!(name) do
    unless is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,31}\z/, name),
      do: raise(ArgumentError, "bot must match ^[a-z][a-z0-9_-]{0,31}$")

    name
  end

  def call(client, method, args \\ %{}, opts \\ []) when is_map(args) do
    bot = validate_name!(Keyword.get(opts, :bot, "default"))
    method = to_string(method)

    if method in @methods do
      payload = JSON.encode!(%{"method" => method, "args" => args, "bot" => bot})

      lua =
        "local request=helpers.json_to_table(" <>
          lua_string(payload) <>
          "); " <>
          "rcon.print(helpers.table_to_json(remote.call('bot','request',request)))"

      with {:ok, body} <- Rcon.lua(client, lua, Keyword.get(opts, :timeout, 5_000)),
           {:ok, result} <- JSON.decode(body) do
        {:ok, result}
      end
    else
      {:error, :unknown_method}
    end
  end

  @doc "Poll an accepted action to a terminal state, without reissuing it."
  def await(client, id, timeout \\ 65_000, opts \\ []) do
    validate_name!(Keyword.get(opts, :bot, "default"))
    await_until(client, id, System.monotonic_time(:millisecond) + timeout, opts)
  end

  defp await_until(client, id, deadline, opts) do
    with {:ok, result} <- call(client, :action, %{"id" => id}, opts) do
      case result do
        %{"ok" => true, "data" => %{"status" => "running"}} ->
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(100)
            await_until(client, id, deadline, opts)
          else
            {:error, {:await_timeout, id}}
          end

        _ ->
          {:ok, result}
      end
    end
  end

  # Decimal byte escapes avoid Lua/JSON escaping differences and code injection.
  defp lua_string(binary) do
    "\"" <>
      for(<<byte <- binary>>,
        into: "",
        do: "\\" <> String.pad_leading(Integer.to_string(byte), 3, "0")
      ) <> "\""
  end
end
