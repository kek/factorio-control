defmodule FactorioControl.MixProject do
  use Mix.Project

  def project do
    [app: :factorio_control, version: "0.1.0", elixir: "~> 1.18", deps: []]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
