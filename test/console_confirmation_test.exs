defmodule FactorioControl.ConsoleConfirmationTest do
  use ExUnit.Case, async: true
  alias FactorioControl.Eyg

  @code """
  match perform ConfirmLuaConsole({confirm: True({})}) {
    Ok(s) -> {{success: True({}), confirmed: s.confirmed, error: ""}}
    Error(e) -> {{success: False({}), confirmed: False({}), error: e}}
  }
  """

  test "confirmation requires an explicit effect grant even with a host callback" do
    refute "ConfirmLuaConsole" in Eyg.default_effects()

    assert {:ok, %{"ok" => false, "error" => error}, _} =
             Eyg.run(nil, @code,
               confirm_lua_console: fn -> flunk("must not confirm implicitly") end
             )

    assert error =~ "type check"
  end

  test "explicit grant alone cannot provide host consent" do
    assert {:ok, %{"ok" => true, "value" => %{"success" => false, "error" => error}}, _} =
             Eyg.run(nil, @code, effects: ["ConfirmLuaConsole"])

    assert error =~ "confirmation_required"
  end

  test "false confirmation never calls transport" do
    code = String.replace(@code, "confirm: True({})", "confirm: False({})")

    assert {:ok, %{"ok" => true, "value" => %{"success" => false}}, _} =
             Eyg.run(nil, code,
               effects: ["ConfirmLuaConsole"],
               confirm_lua_console: fn -> flunk("false is not consent") end
             )
  end

  test "typed explicit confirmation returns and traces the host acknowledgement" do
    assert {:ok, %{"ok" => true, "value" => %{"success" => true, "confirmed" => true}}, trace} =
             Eyg.run(nil, @code,
               effects: ["ConfirmLuaConsole"],
               confirm_lua_console: fn ->
                 {:ok, %{"ok" => true, "data" => %{"confirmed" => true}}}
               end
             )

    assert Enum.any?(trace, &match?(%{type: "game_receipt", method: "confirm_lua_console"}, &1))
  end
end
