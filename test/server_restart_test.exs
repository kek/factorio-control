defmodule FactorioControl.ServerRestartTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Server

  defp fixture(opts \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "factorio-restart-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir!(dir)
    path = Path.join(dir, "fake-factorio")

    File.write!(path, """
    #!/bin/sh
    test "$PWD" = "$1" || exit 8
    test "$FACTORIO_RCON_PASSWORD" = restart-test-password || exit 9
    n=0
    [ ! -f starts ] || n=$(cat starts)
    n=$((n+1))
    printf '%s' "$n" > starts
    printf '%s start\n' "$n" >> events
    printf 'Boot %s\n' "$n"
    if [ "$n" -eq 2 ]; then
      while [ ! -e ready2 ]; do sleep 0.01; done
    fi
    printf 'Starting RCON interface\n'
    while IFS= read -r command; do
      [ "$command" = /quit ] || exit 10
      printf '%s quit\n' "$n" >> events
      while [ ! -e release ]; do sleep 0.01; done
      printf '%s saved\n' "$n" >> events
      printf 'Save finished %s\n' "$n"
      if [ -f fail-exit ]; then exit 17; fi
      exit 0
    done
    exit 11
    """)

    File.chmod!(path, 0o700)

    {:ok, server} =
      Server.start_link(
        Keyword.merge(
          [
            executable: path,
            directory: dir,
            args: [dir],
            password: "restart-test-password"
          ],
          opts
        )
      )

    Process.unlink(server)

    on_exit(fn ->
      File.touch!(Path.join(dir, "ready2"))
      File.touch!(Path.join(dir, "release"))

      if Process.alive?(server) do
        :ok = Server.stop(server)
        GenServer.stop(server)
      end

      File.rm_rf!(dir)
    end)

    assert Server.await_ready(server) == :ok
    {server, dir, path}
  end

  defp eventually(fun, attempts \\ 200)
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

  defp events(dir),
    do: dir |> Path.join("events") |> File.read!() |> String.split("\n", trim: true)

  defp touch(dir, name), do: File.touch!(Path.join(dir, name))

  test "restart waits for saved exit, deduplicates requests and keeps the same owner and launch spec" do
    {server, dir, _} = fixture()
    :ok = Server.subscribe(server)
    old_pid = Server.status(server).os_pid
    first = Task.async(fn -> Server.restart(server) end)
    eventually(fn -> "1 quit" in events(dir) end)
    second = Task.async(fn -> Server.restart(server) end)
    # Synchronize both requests without assuming scheduler ordering.
    eventually(fn -> length(:sys.get_state(server).restart_waiters) == 2 end)
    assert Task.yield(first, 0) == nil
    assert Task.yield(second, 0) == nil
    assert events(dir) == ["1 start", "1 quit"]
    touch(dir, "release")
    assert Task.await(first) == :ok
    assert Task.await(second) == :ok
    assert_receive {:factorio, ^server, {:restarted, new_pid}}, 2000
    assert new_pid != old_pid
    eventually(fn -> "2 start" in events(dir) end)
    assert events(dir) == ["1 start", "1 quit", "1 saved", "2 start"]
    assert Process.alive?(server)
    assert Server.await_ready(server, 0) == {:error, :startup_timeout}
    eventually(fn -> Server.status(server).output =~ "Boot 2" end)
    refute Server.status(server).output =~ "Starting RCON interface"
    refute_receive {:factorio, ^server, {:exit_status, 0}}
    touch(dir, "ready2")
    assert Server.await_ready(server) == :ok
    assert Server.stop(server) == :ok
  end

  test "timeout clears restart intent and a late clean exit never relaunches" do
    {server, dir, _} = fixture(shutdown_timeout: 30)
    assert Server.restart(server) == {:error, :shutdown_timeout}
    assert Server.status(server).state == :stopping
    assert events(dir) == ["1 start", "1 quit"]
    touch(dir, "release")
    assert Server.await_exit(server) == {:ok, 0}
    assert events(dir) == ["1 start", "1 quit", "1 saved"]
    assert File.read!(Path.join(dir, "starts")) == "1"
  end

  test "explicit stop cancels a pending restart, as used by SIGTERM" do
    {server, dir, _} = fixture()
    restarting = Task.async(fn -> Server.restart(server) end)
    eventually(fn -> "1 quit" in events(dir) end)
    stopping = Task.async(fn -> Server.stop(server) end)
    assert Task.await(restarting) == {:error, :restart_cancelled}
    assert Server.restart(server) == {:error, :shutdown_in_progress}
    touch(dir, "release")
    assert Task.await(stopping) == :ok
    assert Server.restart(server) == {:error, :shutdown_requested}
    assert events(dir) == ["1 start", "1 quit", "1 saved"]
  end

  test "nonzero shutdown is reported and never starts another process" do
    {server, dir, _} = fixture()
    touch(dir, "fail-exit")
    touch(dir, "release")
    assert Server.restart(server) == {:error, {:exit_status, 17}}
    assert Server.await_exit(server) == {:ok, 17}
    assert Server.restart(server) == {:error, {:exit_status, 17}}
    assert File.read!(Path.join(dir, "starts")) == "1"
  end

  test "failed relaunch is explicit after clean shutdown" do
    {server, dir, executable} = fixture()
    :ok = Server.subscribe(server)
    File.rm!(executable)
    touch(dir, "release")
    assert Server.restart(server) == {:error, :could_not_start_server}
    assert_receive {:factorio, ^server, {:restart_failed, :could_not_start_server}}, 2000
    assert Server.status(server).state == :exited
    assert Server.status(server).exit_status == 0
    assert File.read!(Path.join(dir, "starts")) == "1"
  end

  test "a stale shutdown timeout cannot cancel a later restart" do
    {server, dir, _} = fixture()
    first = Task.async(fn -> Server.restart(server) end)
    eventually(fn -> "1 quit" in events(dir) end)
    old_tag = :sys.get_state(server).shutdown_tag
    touch(dir, "release")
    touch(dir, "ready2")
    assert Task.await(first) == :ok
    assert Server.await_ready(server) == :ok
    File.rm!(Path.join(dir, "release"))
    second = Task.async(fn -> Server.restart(server) end)
    eventually(fn -> "2 quit" in events(dir) end)
    send(server, {:shutdown_timeout, old_tag})
    assert Server.status(server).state == :stopping
    assert Task.yield(second, 0) == nil
    touch(dir, "release")
    assert Task.await(second) == :ok
    assert Server.await_ready(server) == :ok
    assert File.read!(Path.join(dir, "starts")) == "3"
  end

  test "retained launch password is redacted from diagnostic status" do
    {server, _, _} = fixture()
    refute inspect(:sys.get_status(server)) =~ "restart-test-password"
    refute inspect(Server.status(server)) =~ "restart-test-password"
  end
end
