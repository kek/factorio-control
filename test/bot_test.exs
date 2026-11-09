defmodule FactorioControl.BotTest do
  use ExUnit.Case, async: true
  alias FactorioControl.{Bot, Eyg}

  defmodule FakeRcon do
    use GenServer

    def start_link(handler), do: GenServer.start_link(__MODULE__, handler)
    def init(handler), do: {:ok, handler}

    def handle_call({:lua, source, _timeout}, _from, handler) do
      [_, encoded] = Regex.run(~r/json_to_table\("([^"]*)"\)/, source)

      request =
        Regex.scan(~r/\\(\d{3})/, encoded)
        |> Enum.map(fn [_, byte] -> String.to_integer(byte) end)
        |> :erlang.list_to_binary()
        |> JSON.decode!()

      {:reply, {:ok, JSON.encode!(handler.(request))}, handler}
    end
  end

  defp client(handler), do: start_supervised!({FakeRcon, handler})
  defp ok(data), do: %{"ok" => true, "tick" => 1, "data" => data}

  test "calls select the default or named bot in the envelope, not in method arguments" do
    owner = self()

    client =
      client(fn request ->
        send(owner, {:request, request})
        ok(%{})
      end)

    for {opts, bot} <- [{[], "default"}, {[bot: "miner-2_a"], "miner-2_a"}] do
      assert {:ok, _} = Bot.call(client, :inspect, %{"radius" => 0}, opts)

      assert_received {:request,
                       %{
                         "bot" => ^bot,
                         "method" => "inspect",
                         "args" => %{"radius" => 0}
                       }}
    end
  end

  test "selectors validate the exact ASCII grammar and length before transport or evaluation" do
    for bot <- ["a", "default", "bot_2-x", String.duplicate("a", 32)] do
      assert Bot.validate_name!(bot) == bot
    end

    for bot <- [
          nil,
          :default,
          1,
          "",
          "A",
          "2a",
          "a.b",
          "a b",
          "a\n",
          "é",
          String.duplicate("a", 33)
        ] do
      assert_raise ArgumentError, ~r/bot must match/, fn ->
        Bot.call(nil, :inspect, %{}, bot: bot)
      end

      assert_raise ArgumentError, ~r/bot must match/, fn ->
        Bot.await(nil, 1, 100, bot: bot)
      end

      assert_raise ArgumentError, ~r/bot must match/, fn ->
        Eyg.run(nil, "1",
          bot: bot,
          call: fn _, _ -> flunk("must validate before invoking injected calls") end,
          await: fn _ -> flunk("must validate before awaiting") end
        )
      end
    end
  end

  test "await retains selection on repeated polls and preserves its old timeout API" do
    owner = self()

    client =
      client(fn %{"bot" => bot, "method" => "action", "args" => %{"id" => 7}} ->
        send(owner, {:poll, bot})
        count = Process.get({:polls, bot}, 0)
        Process.put({:polls, bot}, count + 1)
        ok(%{"id" => 7, "status" => if(count == 0, do: "running", else: "completed")})
      end)

    for bot <- ["miner", "builder"] do
      assert {:ok, %{"data" => %{"status" => "completed"}}} =
               Bot.await(client, 7, 1000, bot: bot)

      assert_received {:poll, ^bot}
      assert_received {:poll, ^bot}
    end

    assert {:error, {:await_timeout, 7}} = Bot.await(client, 7, 0)
    assert_received {:poll, "default"}
    assert {:ok, %{"data" => %{"status" => "completed"}}} = Bot.await(client, 7)
    assert_received {:poll, "default"}
    refute_received {:poll, _}
  end

  test "EYG routes submissions, repeated polling, and cleanup only to the selected bot" do
    owner = self()

    client =
      client(fn %{"bot" => bot, "method" => method} ->
        send(owner, {:request, bot, method})

        case method do
          "walk_to" ->
            ok(%{"id" => 7})

          "action" ->
            count = Process.get({:polls, bot}, 0)
            Process.put({:polls, bot}, count + 1)
            # A running poll followed by an unconfirmed reply must clean up
            # this bot, even though both bots use the same action ID.
            if count == 0,
              do: ok(%{"id" => 7, "status" => "running"}),
              else: %{"ok" => false, "error" => %{"message" => "lost action"}}

          "stop" ->
            ok(%{})
        end
      end)

    code = "perform WalkTo({position: {x2: 0, y2: 0}, timeout_ticks: 60})"

    for bot <- ["miner", "builder"] do
      assert {:error, {:action_unconfirmed, 7, _}, trace} =
               Eyg.run(client, code, bot: bot, effects: ["WalkTo"], timeout: 5000)

      assert List.last(trace).type == "cleanup_stop"
      assert_received {:request, ^bot, "walk_to"}
      assert_received {:request, ^bot, "action"}
      assert_received {:request, ^bot, "action"}
      assert_received {:request, ^bot, "stop"}
      refute_received {:request, _, _}
    end
  end

  test "named EYG runs preserve injected call/2 and await/1 hooks" do
    owner = self()

    assert {:ok, %{"ok" => true}, _} =
             Eyg.run(
               nil,
               "let _ = perform WalkTo({position: {x2: 0, y2: 0}, timeout_ticks: 60})\n1",
               bot: "miner",
               call: fn :walk_to, _ ->
                 send(owner, :called)
                 {:ok, ok(%{"id" => 7})}
               end,
               await: fn 7 ->
                 send(owner, :awaited)
                 {:ok, ok(%{"id" => 7, "status" => "completed"})}
               end
             )

    assert_received :called
    assert_received :awaited
  end
end
