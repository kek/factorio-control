# Factorio Control

A bot that plays Factorio by controlling a character on a headless server. An external Elixir client will send commands over RCON to a small Lua mod, which exposes actions such as walking, building, mining, and inspecting the world.

The longer-term goal is to let an LLM write EYG programs whose effects are handled by the client. The available effects define what the bot can do.

**Status:** design only. The server setup, client, and mod have not been implemented or tested. There is no runnable quick start yet.

The first milestone is to start a Factorio 2.0 headless server, query its tick over RCON, then spawn a bot, walk, and build a furnace while watching from a normal game client.

See [DESIGN.md](DESIGN.md) for the architecture, implementation sequence, and open questions. The original notes are in [Factorio bot handoff.pdf](Factorio%20bot%20handoff.pdf).
