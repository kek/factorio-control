defmodule FactorioControl.SetRecipeTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  defp args(name) do
    %{
      "name" => name,
      "position" => %{"x2" => 3, "y2" => 5},
      "recipe" => "iron-gear-wheel"
    }
  end

  defp source(name) do
    """
    match perform SetRecipe({name: "#{name}", position: {x2: 3, y2: 5}, recipe: "iron-gear-wheel"}) {
      Ok(r) -> {{success: True({}), error: "", tick: r.tick}}
      Error(e) -> {{success: False({}), error: e, tick: 0}}
    }
    """
  end

  test "typed SetRecipe forwards later-tier and modded assembler names exactly once" do
    for name <- ["assembling-machine-2", "assembling-machine-3", "modded-assembler"] do
      owner = self()

      call = fn :set_recipe, request ->
        send(owner, {:configured, request})
        {:ok, %{"ok" => true, "tick" => 100, "data" => %{"recipe" => "iron-gear-wheel"}}}
      end

      assert {:ok, %{"value" => %{"success" => true, "tick" => 100}}, trace} =
               Eyg.run(nil, source(name), effects: ["SetRecipe"], call: call)

      assert_received {:configured,
                       %{
                         "name" => ^name,
                         "position" => %{"x" => 1.5, "y" => 2.5},
                         "recipe" => "iron-gear-wheel"
                       }}

      refute_received {:configured, _}
      refute Enum.any?(trace, &match?(%{type: "action_submission"}, &1))
      refute Enum.any?(trace, &match?(%{type: "cleanup_stop"}, &1))
    end
  end

  test "confirmed safety and native postcondition failures are returned without retry" do
    for code <- [
          "unsupported_machine",
          "unsupported_recipe",
          "machine_not_empty",
          "recipe_locked",
          "unexpected_recipe_items",
          "recipe_failed"
        ] do
      owner = self()

      call = fn :set_recipe, _ ->
        send(owner, :attempt)

        {:ok,
         %{
           "ok" => false,
           "tick" => 100,
           "error" => %{"code" => code, "message" => "inspect machine before continuing"}
         }}
      end

      assert {:ok, %{"value" => %{"success" => false, "error" => error}}, trace} =
               Eyg.run(nil, source("modded-assembler"), effects: ["SetRecipe"], call: call)

      assert error =~ code
      assert_received :attempt
      refute_received :attempt
      refute Enum.any?(trace, &match?(%{type: "cleanup_stop"}, &1))
    end
  end

  test "lost SetRecipe acceptance is fatal and never replays the mutation" do
    owner = self()

    call = fn method, _ ->
      send(owner, {:called, method})
      {:error, {:unknown_outcome, :closed}}
    end

    assert {:error, {:game_outcome_unconfirmed, :set_recipe, _}, trace} =
             Eyg.run(nil, source("assembling-machine-3"), effects: ["SetRecipe"], call: call)

    assert_received {:called, :set_recipe}
    refute_received {:called, _}
    refute Enum.any?(trace, &match?(%{type: "cleanup_stop"}, &1))
  end

  test "invalid arguments fail before contacting the game" do
    for request <- [
          Map.put(args("assembling-machine-2"), "name", ""),
          Map.put(args("assembling-machine-2"), "recipe", ""),
          Map.put(args("assembling-machine-2"), "position", %{"x2" => 1.5, "y2" => 5})
        ] do
      assert {:error, _} =
               Eyg.handle(
                 "SetRecipe",
                 request,
                 fn _, _ -> flunk("invalid request reached game") end,
                 nil
               )
    end
  end
end
