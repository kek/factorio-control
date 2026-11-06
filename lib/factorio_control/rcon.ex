defmodule FactorioControl.Rcon do
  @moduledoc """
  Serialized, authenticated Source RCON connection. Lua replies are terminated by
  a unique in-band marker, including replies split over multiple packets.

  Transport/protocol failures close the socket. Commands are never retried:
  after a lost reply, the caller must inspect game state before issuing another
  mutation. A timeout is an unknown outcome, not evidence of failure in-game.
  """
  use GenServer
  @max_packet 4 * 1024 * 1024
  @max_response 16 * 1024 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def close(client), do: GenServer.stop(client)

  @doc "Run administrator Lua; gameplay callers should use FactorioControl.Bot.call/4."
  def lua(client, source, timeout \\ 5_000) when is_binary(source) and timeout > 0 do
    GenServer.call(client, {:lua, source, timeout}, :infinity)
  end

  @impl true
  def init(opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    host = opts |> Keyword.get(:host, "localhost") |> to_charlist()
    port = Keyword.get(opts, :port, 27015)
    password = Keyword.fetch!(opts, :password)

    case :gen_tcp.connect(
           host,
           port,
           [
             :binary,
             active: false,
             packet: :raw,
             send_timeout: timeout,
             send_timeout_close: true
           ],
           timeout
         ) do
      {:ok, socket} ->
        deadline = deadline(timeout)

        with :ok <- send_packet(socket, 1, 3, password),
             :ok <- authenticate(socket, deadline, 4) do
          {:ok, %{socket: socket, id: 1}}
        else
          {:error, reason} ->
            :gen_tcp.close(socket)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:lua, _source, _timeout}, _from, %{socket: nil} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  def handle_call({:lua, source, timeout}, _from, state) do
    id = rem(state.id, 2_147_483_646) + 1
    marker = "__FACTORIO_CONTROL_" <> Base.encode16(:crypto.strong_rand_bytes(16)) <> "__"
    # pcall ensures even a Lua error produces a completion marker. The remote
    # interface returns structured errors; this catches missing mods/API errors.
    command =
      "/sc local ok,err=pcall(function() " <>
        source <>
        " end); if not ok then rcon.print(helpers.table_to_json({ok=false,error={code='lua_error',message=tostring(err)}})) end; rcon.print('" <>
        marker <> "')"

    deadline = deadline(timeout)

    result =
      with :ok <- :inet.setopts(state.socket, send_timeout: timeout),
           :ok <- send_packet(state.socket, id, 2, command) do
        response(state.socket, id, marker, deadline, "", 0)
      end

    case result do
      {:ok, body} ->
        {:reply, {:ok, body}, %{state | id: id}}

      {:error, reason} ->
        :gen_tcp.close(state.socket)
        {:reply, {:error, {:unknown_outcome, reason}}, %{state | socket: nil, id: id}}
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when not is_nil(socket), do: :gen_tcp.close(socket)
  def terminate(_reason, _state), do: :ok

  defp authenticate(_socket, _deadline, 0), do: {:error, :invalid_auth_response}

  defp authenticate(socket, deadline, remaining) do
    case recv_packet(socket, deadline) do
      {:ok, {-1, _, _}} -> {:error, :authentication_failed}
      {:ok, {1, 2, ""}} -> :ok
      {:ok, {1, 0, ""}} -> authenticate(socket, deadline, remaining - 1)
      {:ok, _} -> {:error, :invalid_auth_response}
      error -> error
    end
  end

  defp response(_socket, _id, _marker, _deadline, _body, 16384), do: {:error, :too_many_packets}

  defp response(socket, id, marker, deadline, body, packets) do
    case recv_packet(socket, deadline) do
      # Some versions send empty response/terminator packets. They carry no data.
      {:ok, {_response_id, 0, ""}} ->
        response(socket, id, marker, deadline, body, packets + 1)

      {:ok, {^id, 0, part}} when byte_size(body) + byte_size(part) <= @max_response ->
        body = body <> part

        case :binary.match(body, marker) do
          {offset, _length} -> {:ok, body |> binary_part(0, offset) |> String.trim()}
          :nomatch -> response(socket, id, marker, deadline, body, packets + 1)
        end

      {:ok, {^id, 0, _}} ->
        {:error, :response_too_large}

      {:ok, _} ->
        {:error, :unexpected_response}

      error ->
        error
    end
  end

  defp send_packet(socket, id, type, body) do
    if String.contains?(body, <<0>>) do
      {:error, :nul_in_body}
    else
      :gen_tcp.send(
        socket,
        <<byte_size(body) + 10::little-signed-32, id::little-signed-32, type::little-signed-32,
          body::binary, 0, 0>>
      )
    end
  end

  defp recv_packet(socket, deadline) do
    with {:ok, <<length::little-signed-32>>} <- recv(socket, 4, deadline),
         true <- length >= 10 and length <= @max_packet,
         {:ok, data} <- recv(socket, length, deadline) do
      <<id::little-signed-32, type::little-signed-32, tail::binary>> = data

      if binary_part(tail, byte_size(tail) - 2, 2) == <<0, 0>> do
        {:ok, {id, type, binary_part(tail, 0, byte_size(tail) - 2)}}
      else
        {:error, :invalid_terminator}
      end
    else
      false -> {:error, :invalid_packet_length}
      error -> error
    end
  end

  defp recv(socket, count, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> :gen_tcp.recv(socket, count, remaining)
      _ -> {:error, :timeout}
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end
