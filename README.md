# Phoenix + ExRatatui Example

A minimal Phoenix 1.8 application with an **admin TUI you reach over SSH**. The web app is a tiny chat room. Everything posted in the browser appears live in any terminal connected to the SSH admin TUI — no special client, no extra port forwarding, no agent on the box.

The point of this repo is to show that any Phoenix or LiveView codebase can ship a real terminal admin dashboard with about 30 lines of code, using [`ExRatatui`](https://github.com/mcass19/ex_ratatui)'s SSH transport.

## What you get

- **`/`** — a public chat room LiveView (`PhoenixExRatatuiExampleWeb.ChatLive`). Pick a username, post a message, watch others post in real time.
- **`ssh -p 2222 admin@localhost`** — drops you straight into a TUI (`PhoenixExRatatuiExample.AdminTui`) that subscribes to the same `Phoenix.PubSub` topic as the LiveView. New chat messages stream in immediately. Two tabs:
  - **Overview** — node, BEAM uptime, message count, last activity.
  - **Messages** — live tail of the room.
- **No global TTY required.** Each SSH client gets its own isolated session. Multiple ops engineers can be in the TUI simultaneously without stepping on each other.

## Quick start

```sh
git clone https://github.com/mcass19/phoenix_ex_ratatui_example.git
cd phoenix_ex_ratatui_example
mix setup
mix phx.server
```

Then in two terminals:

```sh
# Browser-side: post some messages
open http://localhost:4000/

# Terminal-side: watch them stream into the admin TUI
ssh -p 2222 admin@localhost           # password: admin
```

Quit the TUI with `q`. Quit Phoenix with `Ctrl+C` twice.

## How the admin TUI is wired up

Two pieces:

### 1. The `ExRatatui.App` module

[`lib/phoenix_ex_ratatui_example/admin_tui.ex`](lib/phoenix_ex_ratatui_example/admin_tui.ex) implements `mount/1`, `render/2`, `handle_event/2`, and `handle_info/2`. It subscribes to `PhoenixExRatatuiExample.Chat`'s PubSub topic in `mount/1`, re-renders whenever a `{:new_message, _}` arrives, and quits on `q`. Standard ExRatatui app — nothing in it knows it's being served over SSH.

> **Note:** Render is event-driven. The TUI only re-paints when a chat message arrives, a presence event fires, or a key is pressed — so the uptime line on the Overview tab stands still between events. That is a deliberate trade-off (no idle wakeups, no wasted bytes on the SSH wire). If you want a continuously ticking dashboard, schedule a `Process.send_after(self(), :tick, 1_000)` from `mount/1` and handle `:tick` in `handle_info/2` — `examples/system_monitor.exs` in the `ex_ratatui` repo is the canonical pattern.

### 2. The supervision tree

[`lib/phoenix_ex_ratatui_example/application.ex`](lib/phoenix_ex_ratatui_example/application.ex) adds the admin TUI directly as a child, alongside `Phoenix.PubSub`, the chat GenServer, and the endpoint:

```elixir
children = [
  PhoenixExRatatuiExampleWeb.Telemetry,
  {Phoenix.PubSub, name: PhoenixExRatatuiExample.PubSub},
  PhoenixExRatatuiExample.Chat,
  {PhoenixExRatatuiExample.AdminTui,
   transport: :ssh,
   port: 2222,
   auto_host_key: true,
   auth_methods: ~c"password",
   user_passwords: [{~c"admin", ~c"admin"}]},
  PhoenixExRatatuiExampleWeb.Endpoint
]
```

That's the whole thing. `transport: :ssh` is what flips the TUI from "render in the local TTY" to "spin up an SSH daemon and serve a fresh session per client" — under the hood `ExRatatui.App.dispatch_start/1` routes the call to `ExRatatui.SSH.Daemon` and injects `:mod` from the module name, so no separate `mod:` key is needed.

`auto_host_key: true` is the other magic line — the daemon generates an RSA host key under `priv/ssh/` on first boot (gitignored) and reuses it on every subsequent boot, so SSH clients don't see host key warnings between restarts. No wrapper module, no `ssh-keygen`, no extra files to maintain.

## Running the TUI locally for development

Iterating on the TUI itself over SSH is annoying — every code change means quitting, restarting `mix phx.server`, and re-`ssh`'ing. The same module that the SSH daemon serves can also be rendered straight into your current terminal, no round trip. Two ways:

```sh
# 1. From an iex session that already started the app:
iex -S mix phx.server
iex> PhoenixExRatatuiExample.AdminTui.run()

# 2. Or directly, no iex:
mix run -e "PhoenixExRatatuiExample.AdminTui.run()"
```

`run/1` is a tiny convenience wrapper around `start_link/1` + `Process.monitor/1` that blocks until you press `q`. `mix run` boots the full OTP app first — `Phoenix.PubSub`, `PhoenixExRatatuiExample.Chat`, the endpoint bound to <http://localhost:4000> — so messages posted in the browser stream into the local TUI in real time over the same PubSub topic the SSH version listens on. Press `q` to quit; the BEAM exits with `run/1`, so the next invocation always starts from a clean slate.

> **Trade-off:** While the local TUI owns the terminal, the SSH daemon child is still up on port 2222 — both transports happily coexist in the same BEAM. If you don't want the listener at all during dev, set `config :phoenix_ex_ratatui_example, :ssh_admin, false` in `config/dev.exs`.

## Adapting it to your own Phoenix app

1. Add `{:ex_ratatui, "~> 0.6"}` to `mix.exs`.
2. Drop the admin TUI module above into your project (or write your own).
3. Add `{MyApp.MyTui, transport: :ssh, port: 2222, auto_host_key: true, ...}` to the `children` list in your `application.ex`. The `transport: :ssh` key tells `ExRatatui.App.dispatch_start/1` to start a daemon instead of grabbing the local TTY — same module, same callbacks, different transport.
4. Replace the chat-specific bits with whatever you want to expose in the terminal — recently failing Oban jobs, queue depth, live trace of an LV mount, on-call paging stats. Anything you can subscribe to over PubSub or query from a context, you can render in the TUI.
5. **Before shipping to anything that isn't your laptop**, swap the dev password for SSH key auth and pin `:system_dir` to a directory under your own configuration management — see [`ExRatatui.SSH.Daemon`](https://hexdocs.pm/ex_ratatui/ExRatatui.SSH.Daemon.html) for the full options list. `auto_host_key: true` is great for demos and internal tools but it is not production-grade host-key management.

## Configuration

Disable the admin daemon entirely (e.g. in test):

```elixir
# config/test.exs
config :phoenix_ex_ratatui_example, :ssh_admin, false
```

Override its options (anything you set here wins over the defaults baked into `application.ex`):

```elixir
# config/runtime.exs
config :phoenix_ex_ratatui_example, :ssh_admin_opts,
  port: 2222,
  auth_methods: ~c"publickey",
  user_dir: ~c"/etc/ssh/users",
  system_dir: ~c"/etc/ssh"
```

Passing `:system_dir` automatically disables `:auto_host_key`, so you can manage host keys explicitly in production.

## Tests

```sh
mix test
```

Coverage:

- `Chat` — post / list / stats / broadcast (`test/phoenix_ex_ratatui_example/chat_test.exs`)
- `AdminTui` — `mount/1`, `render/2`, `handle_event/2`, `handle_info/2` plus an end-to-end render through `ExRatatui.Server`'s test backend (`test/phoenix_ex_ratatui_example/admin_tui_test.exs`)
- `ChatLive` — render, submit, rename, flash error (`test/phoenix_ex_ratatui_example_web/live/chat_live_test.exs`)

The suite never opens a real SSH listener — `config/test.exs` sets `ssh_admin: false`. The admin TUI's render path is exercised through ExRatatui's headless test backend instead.

## See also

- **[ex_ratatui](https://github.com/mcass19/ex_ratatui)** — the underlying Elixir bindings to Rust [ratatui](https://ratatui.rs), including the [SSH transport guide](https://hexdocs.pm/ex_ratatui/ssh_transport.html).
- **[nerves_ex_ratatui_example](https://github.com/mcass19/nerves_ex_ratatui_example)** — the Nerves counterpart to this project: two TUIs registered as SSH subsystems on a Raspberry Pi via `nerves_ssh`. Same library, different deployment shape.

## License

MIT.
