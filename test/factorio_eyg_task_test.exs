defmodule Mix.Tasks.Factorio.EygTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    directory =
      Path.join(System.tmp_dir!(), "factorio-eyg-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    password = System.get_env("FACTORIO_RCON_PASSWORD")
    System.put_env("FACTORIO_RCON_PASSWORD", "test-secret")

    on_exit(fn ->
      File.rm_rf!(directory)

      if password,
        do: System.put_env("FACTORIO_RCON_PASSWORD", password),
        else: System.delete_env("FACTORIO_RCON_PASSWORD")
    end)

    %{directory: directory}
  end

  defp packet(id, type, body) do
    <<byte_size(body) + 10::little-signed-32, id::little-signed-32, type::little-signed-32,
      body::binary, 0, 0>>
  end

  defp receive_packet(socket) do
    {:ok, <<length::little-signed-32>>} = :gen_tcp.recv(socket, 4, 5000)

    {:ok, <<id::little-signed-32, type::little-signed-32, tail::binary>>} =
      :gen_tcp.recv(socket, length, 5000)

    {id, type, binary_part(tail, 0, byte_size(tail) - 2)}
  end

  for {selection, bot} <- [{[], "default"}, {["--bot", "miner-2"], "miner-2"}] do
    test "CLI records and routes #{bot} selection", %{directory: directory} do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(listener)
      owner = self()

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5000)

          try do
            assert {1, 3, "test-secret"} = receive_packet(socket)
            :ok = :gen_tcp.send(socket, packet(1, 2, ""))
            {id, 2, command} = receive_packet(socket)
            [marker] = Regex.run(~r/__FACTORIO_CONTROL_[0-9A-F]+__/, command)
            [_, encoded] = Regex.run(~r/json_to_table\("([^"]*)"\)/, command)

            request =
              Regex.scan(~r/\\(\d{3})/, encoded)
              |> Enum.map(fn [_, byte] -> String.to_integer(byte) end)
              |> :erlang.list_to_binary()
              |> JSON.decode!()

            send(owner, {:request, request})
            reply = JSON.encode!(%{"ok" => true, "tick" => 1, "data" => %{}})
            :ok = :gen_tcp.send(socket, packet(id, 0, reply <> "\n" <> marker))
          after
            :gen_tcp.close(socket)
          end
        end)

      on_exit(fn ->
        :gen_tcp.close(listener)
        if Process.alive?(server.pid), do: Process.exit(server.pid, :kill)
      end)

      source = Path.join(directory, "stop.eyg")
      trace = Path.join(directory, "trace.jsonl")
      File.write!(source, "let _ = perform Stop({})\n1")

      capture_io(fn ->
        Mix.Tasks.Factorio.Eyg.run(
          unquote(selection) ++
            [
              "--host",
              "127.0.0.1",
              "--port",
              to_string(port),
              "--effects",
              "Stop",
              "--trace",
              trace,
              source
            ]
        )
      end)

      assert_received {:request, %{"bot" => unquote(bot), "method" => "stop"}}
      start = trace |> File.read!() |> String.split("\n", trim: true) |> hd() |> JSON.decode!()
      assert start["type"] == "start"
      assert start["bot"] == unquote(bot)
      Task.await(server)
    end
  end

  test "CLI explicit consent uses a dedicated fixed-command connection", %{directory: directory} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, primary} = :gen_tcp.accept(listener, 5000)
        assert {1, 3, "test-secret"} = receive_packet(primary)
        :ok = :gen_tcp.send(primary, packet(1, 2, ""))
        {:ok, confirmation} = :gen_tcp.accept(listener, 5000)
        assert {1, 3, "test-secret"} = receive_packet(confirmation)
        :ok = :gen_tcp.send(confirmation, packet(1, 2, ""))
        assert {2, 2, first} = receive_packet(confirmation)
        assert {3, 2, ^first} = receive_packet(confirmation)
        [marker] = Regex.run(~r/__FACTORIO_CONTROL_[0-9A-F]+__/, first)
        :ok = :gen_tcp.send(confirmation, packet(3, 0, marker))
        assert {:error, :closed} = :gen_tcp.recv(confirmation, 0, 5000)
        assert {:error, :closed} = :gen_tcp.recv(primary, 0, 5000)
        :gen_tcp.close(confirmation)
        :gen_tcp.close(primary)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Process.exit(server.pid, :kill)
    end)

    source = Path.join(directory, "confirm.eyg")
    trace = Path.join(directory, "confirm.jsonl")
    File.cp!("scenarios/confirm-lua-console.eyg", source)

    text =
      capture_io(fn ->
        Mix.Tasks.Factorio.Eyg.run([
          "--host",
          "127.0.0.1",
          "--port",
          to_string(port),
          "--effects",
          "ConfirmLuaConsole",
          "--confirm-achievements",
          "--trace",
          trace,
          source
        ])
      end)

    assert text =~ "permanently disable achievements"
    assert text =~ "\"confirmed\":true"
    assert File.read!(trace) =~ "confirm_lua_console"
    Task.await(server)
  end

  test "CLI consent flag alone is rejected before opening a trace", %{directory: directory} do
    trace = Path.join(directory, "denied.jsonl")

    assert_raise Mix.Error, ~r/requires an explicit ConfirmLuaConsole grant/, fn ->
      Mix.Tasks.Factorio.Eyg.run(["--confirm-achievements", "--trace", trace, "missing.eyg"])
    end

    refute File.exists?(trace)
  end

  test "CLI rejects invalid selectors before reading source or opening a trace", %{
    directory: directory
  } do
    trace = Path.join(directory, "trace.jsonl")

    for bot <- ["", "Miner", "a\n", String.duplicate("a", 33)] do
      assert_raise Mix.Error, ~r/--bot must match/, fn ->
        Mix.Tasks.Factorio.Eyg.run(["--bot", bot, "--trace", trace, "missing.eyg"])
      end
    end

    refute File.exists?(trace)
  end
end
