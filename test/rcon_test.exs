defmodule FactorioControl.RconTest do
  use ExUnit.Case, async: true
  alias FactorioControl.{Bot, Rcon}

  defp packet(id, type, body) do
    <<byte_size(body) + 10::little-signed-32, id::little-signed-32, type::little-signed-32,
      body::binary, 0, 0>>
  end

  defp receive_packet(socket) do
    {:ok, <<length::little-signed-32>>} = :gen_tcp.recv(socket, 4, 2000)

    {:ok, <<id::little-signed-32, type::little-signed-32, tail::binary>>} =
      :gen_tcp.recv(socket, length, 2000)

    {id, type, binary_part(tail, 0, byte_size(tail) - 2)}
  end

  defp server(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        :gen_tcp.close(listener)

        try do
          handler.(socket)
        after
          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
      :gen_tcp.close(listener)
    end)

    {port, task}
  end

  defp auth(socket) do
    assert {1, 3, "secret"} = receive_packet(socket)
    :ok = :gen_tcp.send(socket, packet(1, 0, "") <> packet(1, 2, ""))
  end

  defp marker(command) do
    [marker] = Regex.run(~r/__FACTORIO_CONTROL_[0-9A-F]+__/, command)
    marker
  end

  test "authentication, fragmented TCP reads, multipart replies, and empty trailing packets" do
    {port, task} =
      server(fn socket ->
        auth(socket)
        {id, 2, command} = receive_packet(socket)
        marker = marker(command)
        <<first::binary-size(12), rest::binary>> = packet(id, 0, "hello ")
        :ok = :gen_tcp.send(socket, first)
        Process.sleep(10)
        :ok = :gen_tcp.send(socket, rest <> packet(id, 0, "world\n" <> binary_part(marker, 0, 8)))

        :ok =
          :gen_tcp.send(
            socket,
            packet(id, 0, binary_part(marker, 8, byte_size(marker) - 8) <> "\n") <>
              packet(id, 0, "")
          )

        {next_id, 2, next} = receive_packet(socket)
        :ok = :gen_tcp.send(socket, packet(next_id, 0, "next\n" <> marker(next)))
      end)

    {:ok, client} = Rcon.start_link(host: "127.0.0.1", port: port, password: "secret")
    assert {:ok, "hello world"} = Rcon.lua(client, "rcon.print('hello world')")
    assert {:ok, "next"} = Rcon.lua(client, "rcon.print('next')")
    Rcon.close(client)
    Task.await(task)
  end

  test "rejects bad authentication" do
    Process.flag(:trap_exit, true)

    {port, task} =
      server(fn socket ->
        receive_packet(socket)
        :gen_tcp.send(socket, packet(-1, 2, ""))
      end)

    assert {:error, :authentication_failed} =
             Rcon.start_link(host: "127.0.0.1", port: port, password: "wrong")

    Task.await(task)
  end

  test "a lost response is an unknown outcome and mutations are never retried" do
    {port, task} =
      server(fn socket ->
        auth(socket)
        {_id, 2, _command} = receive_packet(socket)
        :gen_tcp.close(socket)
      end)

    {:ok, client} = Rcon.start_link(host: "127.0.0.1", port: port, password: "secret")
    assert {:error, {:unknown_outcome, :closed}} = Rcon.lua(client, "mutate()")
    assert {:error, :disconnected} = Rcon.lua(client, "mutate()")
    Rcon.close(client)
    Task.await(task)
  end

  for {name, response, reason} <- [
        {"invalid length", <<9::little-signed-32>>, :invalid_packet_length},
        {"oversized frame", <<4_194_305::little-signed-32>>, :invalid_packet_length},
        {"wrong request ID",
         <<20::little-signed-32, 99::little-signed-32, 0::little-signed-32, "unexpected", 0, 0>>,
         :unexpected_response},
        {"invalid terminator",
         <<10::little-signed-32, 2::little-signed-32, 0::little-signed-32, 1, 0>>,
         :invalid_terminator}
      ] do
    test "rejects #{name}" do
      response = unquote(response)

      {port, task} =
        server(fn socket ->
          auth(socket)
          receive_packet(socket)
          :gen_tcp.send(socket, response)
        end)

      {:ok, client} = Rcon.start_link(host: "127.0.0.1", port: port, password: "secret")
      assert {:error, {:unknown_outcome, unquote(reason)}} = Rcon.lua(client, "query()")
      Rcon.close(client)
      Task.await(task)
    end
  end

  test "deadline applies to the entire response even while packets keep arriving" do
    {port, task} =
      server(fn socket ->
        auth(socket)
        {id, 2, _} = receive_packet(socket)

        Enum.reduce_while(1..20, nil, fn _, _ ->
          Process.sleep(10)

          case :gen_tcp.send(socket, packet(id, 0, "")) do
            :ok -> {:cont, nil}
            _ -> {:halt, nil}
          end
        end)
      end)

    {:ok, client} = Rcon.start_link(host: "127.0.0.1", port: port, password: "secret")
    assert {:error, {:unknown_outcome, :timeout}} = Rcon.lua(client, "query()", 50)
    Rcon.close(client)
    Task.await(task)
  end

  test "bot adapter encodes input as data, decodes errors, and rejects unknown methods" do
    {port, task} =
      server(fn socket ->
        auth(socket)
        {id, 2, command} = receive_packet(socket)
        refute command =~ "injected()"
        assert command =~ "helpers.json_to_table"
        result = JSON.encode!(%{ok: false, error: %{code: "invalid_argument"}})
        :gen_tcp.send(socket, packet(id, 0, result <> "\n" <> marker(command)))
      end)

    {:ok, client} = Rcon.start_link(host: "127.0.0.1", port: port, password: "secret")
    assert {:error, :unknown_method} = Bot.call(client, :arbitrary_lua)
    assert {:ok, %{"ok" => false}} = Bot.call(client, :build, %{"item" => "'); injected(); --"})
    Rcon.close(client)
    Task.await(task)
  end
end
