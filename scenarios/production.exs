# An opt-in integration check on the POC world. Uses the existing iron line at
# (29,-42)/(29,-40), mines real coal, then refuels it. It creates no items.
alias FactorioControl.{Bot, Rcon}

defmodule ProductionCheck do
  def call(c, method, args \\ %{}) do
    case Bot.call(c, method, args) do
      {:ok, %{"ok" => true, "data" => data}} -> data
      other -> raise "#{method}: #{inspect(other)}"
    end
  end

  def action(c, method, args) do
    %{"id" => id} = call(c, method, args)

    case Bot.await(c, id) do
      {:ok, %{"ok" => true, "data" => %{"status" => "completed"}}} -> :ok
      other -> raise "#{method} action #{id}: #{inspect(other)}"
    end
  end
end

{:ok, c} = Rcon.start_link(password: System.fetch_env!("FACTORIO_RCON_PASSWORD"))

try do
  ProductionCheck.call(c, :spawn, %{"position" => %{"x" => 29, "y" => -38}})
  ProductionCheck.call(c, :stop)
  IO.puts("Walking to coal")
  ProductionCheck.action(c, :walk_to, %{"position" => %{"x" => 44, "y" => 17}})
  IO.puts("Mining 12 coal")

  ProductionCheck.action(c, :mine, %{
    "position" => %{"x" => 45.5, "y" => 17.5},
    "item" => "coal",
    "count" => 12
  })

  IO.puts("Returning to the iron line")
  ProductionCheck.action(c, :walk_to, %{"position" => %{"x" => 29, "y" => -38}})
  furnace = %{"x" => 29, "y" => -40}
  drill = %{"x" => 29, "y" => -42}
  snapshot = ProductionCheck.call(c, :inspect, %{"radius" => 5})
  before = Enum.find(snapshot["entities"], &(&1["name"] == "stone-furnace"))

  count = fn e ->
    case e["output"] do
      list when is_list(list) ->
        Enum.reduce(list, 0, fn item, sum ->
          sum + if(item["name"] == "iron-plate", do: item["count"], else: 0)
        end)

      _ ->
        0
    end
  end

  initial = count.(before)

  for {name, pos} <- [{"burner-mining-drill", drill}, {"stone-furnace", furnace}] do
    ProductionCheck.call(c, :transfer, %{
      "entity" => name,
      "position" => pos,
      "inventory" => "fuel",
      "direction" => "give",
      "item" => "coal",
      "count" => 5
    })
  end

  Enum.reduce_while(1..100, nil, fn _, _ ->
    Process.sleep(200)
    now = ProductionCheck.call(c, :inspect, %{"radius" => 5})
    output = now["entities"] |> Enum.find(&(&1["name"] == "stone-furnace")) |> count.()

    if output > initial do
      IO.puts("PASS: furnace output increased from #{initial} to #{output} iron plates")
      {:halt, :ok}
    else
      {:cont, nil}
    end
  end) || raise "Production did not advance in 20 seconds"
after
  # An interrupted action remains bounded by the mod’s tick deadline.
  Rcon.close(c)
end
