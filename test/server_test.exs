defmodule FactorioControl.ServerTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Server

  defp fixture(context, script) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "factorio-port-#{context.test}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "fake-factorio")
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end

  test "Port receives output, detects readiness across chunks, and quits via stdin", context do
    executable =
      fixture(context, """
      test "$FACTORIO_RCON_PASSWORD" = secret || exit 9
      printf 'Starting RCON'
      sleep 0.02
      printf ' interface\\n'
      while IFS= read -r command; do
        if [ "$command" = /quit ]; then
          printf 'Saved and stopped\\n'
          exit 0
        fi
      done
      exit 7
      """)

    {:ok, server} = Server.start_link(executable: executable, password: "secret")
    :ok = Server.subscribe(server)
    assert :ok = Server.await_ready(server)
    assert %{state: :running, os_pid: pid, output: output} = Server.status(server)
    assert is_integer(pid)
    assert output =~ "Starting RCON interface"
    assert_receive {:factorio, ^server, {:output, _}}
    assert :ok = Server.stop(server)
    assert %{state: :exited, exit_status: 0, output: output} = Server.status(server)
    assert output =~ "Saved and stopped"
    assert :ok = Server.stop(server)
    GenServer.stop(server)
  end

  test "an early OS exit is visible rather than silently restarted", context do
    executable = fixture(context, "echo 'startup failed'\nexit 17\n")
    {:ok, server} = Server.start_link(executable: executable, password: "secret")
    assert {:error, {:exit_status, 17}} = Server.await_ready(server)
    assert %{state: :exited, exit_status: 17} = Server.status(server)
    Server.subscribe(server)
    assert_receive {:factorio, ^server, {:exit_status, 17}}
    GenServer.stop(server)
  end

  test "a startup timeout retains ownership so the process can still be stopped", context do
    executable =
      fixture(
        context,
        "while IFS= read -r command; do [ \"$command\" = /quit ] && exit 0; done\n"
      )

    {:ok, server} = Server.start_link(executable: executable, password: "secret")
    assert {:error, :startup_timeout} = Server.await_ready(server, 50)
    assert %{state: :starting} = Server.status(server)
    assert :ok = Server.stop(server)
    GenServer.stop(server)
  end
end
