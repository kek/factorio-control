defmodule FactorioControl.ServerConsoleTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias FactorioControl.{Server, ServerConsole}

  @standard """
  printf 'Starting RCON interface\n'
  while IFS= read -r command; do
    printf '%s\n' "$command" >> "$2"
    [ "$command" = /quit ] || exit 9
    printf 'Saved and stopped\n'
    exit 0
  done
  exit 8
  """

  defp fixture(body \\ @standard, opts \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "factorio-console-" <> Base.encode16(:crypto.strong_rand_bytes(10))
      )

    File.mkdir!(dir)
    executable = Path.join(dir, "fake-factorio")
    release = Path.join(dir, "release")
    commands = Path.join(dir, "commands")
    File.write!(executable, "#!/bin/sh\n" <> body)
    File.chmod!(executable, 0o700)

    {:ok, server} =
      Server.start_link(
        Keyword.merge(
          [executable: executable, password: "unused-test", args: [release, commands]],
          opts
        )
      )

    Process.unlink(server)

    on_exit(fn ->
      File.touch!(release)

      if Process.alive?(server) do
        :ok = Server.stop(server)
        GenServer.stop(server)
      end

      File.rm_rf!(dir)
    end)

    {server, release, commands}
  end

  defp input_device do
    controller = self()
    pid = spawn(fn -> read_requests(controller) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp read_requests(controller) do
    receive do
      {:io_request, from, reply_as, request} when elem(request, 0) == :get_line ->
        send(controller, {:input_requested, self(), from})

        receive do
          {:feed, line} -> send(from, {:io_reply, reply_as, line})
        end

        read_requests(controller)
    end
  end

  defp console(server, input) do
    {:ok, output} = StringIO.open("")
    Process.unlink(output)

    # This is a test-owned in-memory device, not the Port owner. ExUnit may
    # already be shutting it down; an idempotent exit avoids a close-call race.
    on_exit(fn -> Process.exit(output, :kill) end)

    task = Task.async(fn -> ServerConsole.run(server, input: input, output: output) end)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    {task, output}
  end

  defp output(io), do: io |> StringIO.contents() |> elem(1)

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  test "q and quit use the Port owner and work on standard input" do
    for command <- ["q\n", "quit\n", " Q \r\n"] do
      {server, _, commands} = fixture()
      text = capture_io([input: command], fn -> assert ServerConsole.run(server) == :ok end)
      assert text =~ "Type q then Enter"
      assert text =~ "Saved and stopped"
      assert File.read!(commands) == "/quit\n"
      assert %{state: :exited, exit_status: 0} = Server.status(server)
    end
  end

  test "output continues while saving, repeated q is ignored, and exit is awaited" do
    {server, release, commands} =
      fixture("""
      printf 'Starting RCON interface\n'
      while IFS= read -r command; do
        printf '%s\n' "$command" >> "$2"
        [ "$command" = /quit ] || exit 9
        printf 'Saving now\n'
        while [ ! -e "$1" ]; do sleep 0.01; done
        printf 'Save finished, goodbye\n'
        exit 0
      done
      """)

    input = input_device()
    {task, io} = console(server, input)
    assert_receive {:input_requested, ^input, _}, 2000
    send(input, {:feed, "q\n"})
    eventually(fn -> output(io) =~ "Saving now" end)
    assert Task.yield(task, 0) == nil
    assert_receive {:input_requested, ^input, _}, 2000
    send(input, {:feed, "q\n"})
    eventually(fn -> File.read!(commands) == "/quit\n" end)
    File.touch!(release)
    assert Task.await(task, 5000) == :ok
    assert output(io) =~ "Save finished, goodbye"
    assert File.read!(commands) == "/quit\n"
  end

  test "unrecognized input is never forwarded as a game command" do
    {server, _, commands} = fixture()

    text =
      capture_io([input: "status\n/c bad\n\nq\n"], fn ->
        assert ServerConsole.run(server) == :ok
      end)

    assert text =~ "Other input is not sent to the game"
    assert File.read!(commands) == "/quit\n"
  end

  test "EOF does not stop the server or spin, and external stop still ends streaming" do
    {server, _, commands} = fixture()
    assert Server.await_ready(server) == :ok
    input = input_device()
    {task, _} = console(server, input)
    assert_receive {:input_requested, ^input, reader}, 2000
    send(input, {:feed, :eof})
    eventually(fn -> not Process.alive?(reader) end)
    assert Task.yield(task, 0) == nil
    refute File.exists?(commands)
    assert Server.stop(server) == :ok
    assert Task.await(task, 5000) == :ok
  end

  test "shutdown timeout remains visible and only an explicit q retries" do
    {server, _, commands} =
      fixture(
        """
        printf 'Starting RCON interface\n'
        n=0
        while IFS= read -r command; do
          printf '%s\n' "$command" >> "$2"
          [ "$command" = /quit ] || exit 9
          n=$((n+1))
          if [ "$n" -eq 2 ]; then printf 'Saved on explicit retry\n'; exit 0; fi
        done
        """,
        shutdown_timeout: 40
      )

    input = input_device()
    {task, io} = console(server, input)
    assert_receive {:input_requested, ^input, _}, 2000
    send(input, {:feed, "q\n"})
    eventually(fn -> output(io) =~ "Shutdown not confirmed" end)
    assert File.read!(commands) == "/quit\n"
    assert Task.yield(task, 0) == nil
    assert %{state: :stopping} = Server.status(server)
    send(input, {:feed, "q\n"})
    assert Task.await(task, 5000) == :ok
    assert File.read!(commands) == "/quit\n/quit\n"
    assert output(io) =~ "Saved on explicit retry"
  end

  test "loss of the owner is reported instead of leaving the console waiting forever" do
    {server, _, commands} = fixture()
    assert Server.await_ready(server) == :ok
    input = input_device()
    {task, _} = console(server, input)
    assert_receive {:input_requested, ^input, reader}, 2000
    GenServer.stop(server)
    assert Task.await(task, 5000) == {:error, {:owner_exit, :normal}}
    eventually(fn -> not Process.alive?(reader) end)
    assert File.read!(commands) == "/quit\n"
  end

  test "r and restart keep the console alive across process exit and allow q afterwards" do
    for command <- ["r\n", "restart\n", " R \r\n"] do
      {server, _, commands} =
        fixture("""
        printf 'boot\n' >> "$2.starts"
        printf 'Starting RCON interface\n'
        while IFS= read -r command; do
          printf '%s\n' "$command" >> "$2"
          [ "$command" = /quit ] || exit 9
          printf 'Save completed\n'
          exit 0
        done
        """)

      input = input_device()
      {task, io} = console(server, input)
      assert_receive {:input_requested, ^input, _}, 2000
      send(input, {:feed, command})
      eventually(fn -> start_count(commands) == 2 end)
      assert Task.yield(task, 0) == nil
      assert output(io) =~ "Previous process exited cleanly"
      send(input, {:feed, "q\n"})
      assert Task.await(task, 5000) == :ok
      assert start_count(commands) == 2
      assert File.read!(commands) == "/quit\n/quit\n"
    end
  end

  test "q cancels a pending r and repeated r does not start extra processes" do
    {server, release, commands} =
      fixture("""
      printf 'boot\n' >> "$2.starts"
      printf 'Starting RCON interface\n'
      while IFS= read -r command; do
        printf '%s\n' "$command" >> "$2"
        while [ ! -e "$1" ]; do sleep 0.01; done
        printf 'Saved and stopped\n'
        exit 0
      done
      """)

    input = input_device()
    {task, _} = console(server, input)
    assert_receive {:input_requested, ^input, _}, 2000
    send(input, {:feed, "r\n"})
    eventually(fn -> File.exists?(commands) end)
    send(input, {:feed, "r\n"})
    send(input, {:feed, "q\n"})
    eventually(fn -> :sys.get_state(server).intent == :quit end)
    File.touch!(release)
    assert Task.await(task, 5000) == :ok
    assert start_count(commands) == 1
    assert File.read!(commands) == "/quit\n"
  end

  test "a failed relaunch ends the console with an explicit error" do
    {server, release, _} = fixture()
    assert Server.await_ready(server) == :ok
    input = input_device()
    {task, _} = console(server, input)
    assert_receive {:input_requested, ^input, _}, 2000
    File.rm!(Path.join(Path.dirname(release), "fake-factorio"))
    send(input, {:feed, "r\n"})
    assert Task.await(task, 5000) == {:error, {:restart_failed, :could_not_start_server}}
  end

  defp start_count(commands) do
    case File.read(commands <> ".starts") do
      {:ok, contents} -> length(String.split(contents, "\n", trim: true))
      _ -> 0
    end
  end

  test "nonzero game exit is returned and a blocked keyboard reader is cleaned up" do
    {server, release, _} =
      fixture("""
      printf 'Starting RCON interface\n'
      while [ ! -e "$1" ]; do sleep 0.01; done
      printf 'Unexpected game exit\n'
      exit 17
      """)

    input = input_device()
    {task, io} = console(server, input)
    assert_receive {:input_requested, ^input, reader}, 2000
    File.touch!(release)
    assert Task.await(task, 5000) == {:error, {:exit_status, 17}}
    eventually(fn -> not Process.alive?(reader) end)
    assert output(io) =~ "Unexpected game exit"
  end
end
