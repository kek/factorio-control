defmodule FactorioControl.ItemTypesTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  defp args(item) do
    %{
      "position" => %{"x2" => 1, "y2" => 1},
      "entity" => "iron-chest",
      "inventory" => "main",
      "direction" => "take",
      "item" => item,
      "count" => 5
    }
  end

  test "Transfer accepts arbitrary item names and reports actual moved counts" do
    for item <- ["blueprint", "power-armor-mk2", "repair-pack", "modded-item"] do
      call = fn :transfer, request ->
        assert request["item"] == item
        {:ok, %{"ok" => true, "tick" => 10, "data" => %{"count" => 2}}}
      end

      assert {:ok, %{"count" => 2, "tick" => 10}} =
               Eyg.handle("Transfer", args(item), call, nil)
    end
  end

  test "Transfer rejects malformed or impossible success receipts as unconfirmed" do
    for data <- [%{}, %{"count" => 0}, %{"count" => 6}, %{"count" => "2"}] do
      call = fn :transfer, _ -> {:ok, %{"ok" => true, "tick" => 10, "data" => data}} end

      assert {:fatal, {:invalid_transfer_receipt, _}} =
               Eyg.handle("Transfer", args("blueprint"), call, nil)
    end
  end

  test "typed EYG programs see partial transfer counts" do
    call = fn :transfer, _ ->
      {:ok, %{"ok" => true, "tick" => 10, "data" => %{"count" => 1}}}
    end

    code = """
    match perform Transfer({position: {x2: 1, y2: 1}, entity: "iron-chest",
      inventory: "main", direction: "take", item: "blueprint", count: 5}) {
      Ok(receipt) -> {receipt.count}
      Error(_) -> {0}
    }
    """

    assert {:ok, %{"value" => 1}, _} = Eyg.run(nil, code, effects: ["Transfer"], call: call)
  end
end
