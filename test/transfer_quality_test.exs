defmodule FactorioControl.TransferQualityTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  defp args do
    %{
      "position" => %{"x2" => 1, "y2" => 1},
      "entity" => "iron-chest",
      "inventory" => "main",
      "direction" => "take",
      "item" => "iron-plate",
      "count" => 5
    }
  end

  defp source(effect, quality_field \\ "") do
    """
    match perform #{effect}({position: {x2: 1, y2: 1}, entity: "iron-chest",
      inventory: "main", direction: "take", item: "iron-plate", count: 5#{quality_field}}) {
      Ok(r) -> {{success: True({}), error: "", count: r.count}}
      Error(e) -> {{success: False({}), error: e, count: 0}}
    }
    """
  end

  defp ok(data), do: {:ok, %{"ok" => true, "tick" => 10, "data" => data}}

  test "legacy Transfer keeps its original typed shape and normal-only wire method" do
    call = fn :transfer, request ->
      refute Map.has_key?(request, "quality")
      ok(%{"count" => 5})
    end

    assert {:ok, %{"value" => %{"success" => true, "count" => 5}}, _} =
             Eyg.run(nil, source("Transfer"), effects: ["Transfer"], call: call)

    assert {:error, error} =
             Eyg.handle(
               "Transfer",
               Map.put(args(), "quality", "rare"),
               fn _, _ -> flunk("legacy quality must not be ignored") end,
               nil
             )

    assert error =~ "TransferQuality"
  end

  test "explicit qualities use the dedicated method and return actual moved counts" do
    for quality <- ["normal", "uncommon", "rare", "epic", "legendary", "modded-quality"] do
      owner = self()

      call = fn :transfer_quality, request ->
        send(owner, {:called, request})
        assert request["quality"] == quality
        ok(%{"count" => 2, "quality" => quality})
      end

      assert {:ok, %{"value" => %{"success" => true, "count" => 2}}, _} =
               Eyg.run(nil, source("TransferQuality", ", quality: \"#{quality}\""),
                 effects: ["TransferQuality"],
                 call: call
               )

      assert_received {:called, %{"quality" => ^quality}}
      refute_received {:called, _}
    end
  end

  test "the quality effect requires a separate grant and exact argument shape" do
    for {code, effects} <- [
          {source("TransferQuality", ", quality: \"rare\""), ["Transfer"]},
          {source("Transfer"), ["TransferQuality"]},
          {source("TransferQuality"), ["TransferQuality"]},
          {source("Transfer", ", quality: \"rare\""), ["Transfer"]}
        ] do
      assert {:ok, %{"ok" => false}, _} =
               Eyg.run(nil, code,
                 effects: effects,
                 call: fn _, _ -> flunk("invalid grant or shape reached game") end
               )
    end
  end

  test "invalid quality arguments are rejected before contacting the game" do
    for quality <- [nil, false, 1, "", String.duplicate("q", 101)] do
      assert {:error, _} =
               Eyg.handle(
                 "TransferQuality",
                 Map.put(args(), "quality", quality),
                 fn _, _ -> flunk("invalid quality reached game") end,
                 nil
               )
    end

    assert {:error, _} =
             Eyg.handle(
               "TransferQuality",
               args(),
               fn _, _ -> flunk("missing quality reached game") end,
               nil
             )
  end

  test "missing or mismatched quality acknowledgements are fatal, never false success" do
    for data <- [
          %{"count" => 2},
          %{"count" => 2, "quality" => "normal"},
          %{"count" => 0, "quality" => "rare"},
          %{"count" => 6, "quality" => "rare"}
        ] do
      assert {:fatal, {:invalid_transfer_receipt, _}} =
               Eyg.handle(
                 "TransferQuality",
                 Map.put(args(), "quality", "rare"),
                 fn :transfer_quality, _ -> ok(data) end,
                 nil
               )
    end
  end

  test "an old mod rejects the dedicated method without a normal-quality fallback" do
    owner = self()

    call = fn method, _ ->
      assert method == :transfer_quality
      send(owner, :attempt)

      {:ok,
       %{
         "ok" => false,
         "tick" => 10,
         "error" => %{"code" => "unknown_method", "message" => "Unknown bot method"}
       }}
    end

    assert {:ok, %{"value" => %{"success" => false, "error" => error}}, _} =
             Eyg.run(nil, source("TransferQuality", ", quality: \"rare\""),
               effects: ["TransferQuality"],
               call: call
             )

    assert error =~ "unknown_method"
    assert_received :attempt
    refute_received :attempt
  end

  test "a lost quality-transfer reply is fatal and never replays or falls back" do
    owner = self()

    call = fn method, _ ->
      send(owner, {:called, method})
      {:error, {:unknown_outcome, :closed}}
    end

    assert {:error, {:game_outcome_unconfirmed, :transfer_quality, _}, trace} =
             Eyg.run(nil, source("TransferQuality", ", quality: \"rare\""),
               effects: ["TransferQuality"],
               call: call
             )

    assert_received {:called, :transfer_quality}
    refute_received {:called, _}
    refute Enum.any?(trace, &match?(%{type: "cleanup_stop"}, &1))
  end
end
