# Phoenix ExRatatui Example

A minimal Phoenix application with an **admin TUI you reach over SSH**. The web app is a tiny chat room. Everything posted in the browser appears live in any terminal connected to the SSH admin TUI — no special client, no extra port forwarding, no agent on the box.

The point of this repo is to show that any Phoenix or LiveView codebase can easily ship a real terminal UI, using [`ExRatatui`](https://github.com/mcass19/ex_ratatui)'s SSH transport.

![Phoenix ExRatatui Demo](https://raw.githubusercontent.com/mcass19/phoenix_ex_ratatui_example/main/assets/phoenix_demo.gif)

## What you get

- **`/`** — a public chat room LiveView (`PhoenixExRatatuiExampleWeb.ChatLive`). Pick a username, post a message, watch others post in real time.
- **`ssh -p 2222 admin@localhost`** — drops you straight into a TUI (`PhoenixExRatatuiExample.AdminTui`) that subscribes to the same `Phoenix.PubSub` topic as the LiveView. New chat messages stream in immediately. Two tabs:
  - **Overview** — node, BEAM uptime, message count, last activity.
  - **Messages** — live tail of the room.
- **No global TTY required.** Each SSH client gets its own isolated session. Multiple can be in the TUI simultaneously without stepping on each other.

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

[`lib/phoenix_ex_ratatui_example/admin_tui.ex`](lib/phoenix_ex_ratatui_example/admin_tui.ex) implements `mount/1`, `render/2`, `handle_event/2`, and `handle_info/2`. It subscribes to `PhoenixExRatatuiExample.Chat`'s PubSub topic in `mount/1`, re-renders whenever a `{:new_message, _}` arrives, and quits on `q`. Standard ExRatatui app, nothing in it knows it's being served over SSH.

> **Note:** Render is event-driven. The TUI only re-paints when a chat message arrives, a presence event fires, or a key is pressed. So the uptime line on the Overview tab stands still between events. That is a deliberate trade-off (no idle wakeups, no wasted bytes on the SSH wire). If you want a continuously ticking dashboard, schedule a `Process.send_after(self(), :tick, 1_000)` from `mount/1` and handle `:tick` in `handle_info/2` — `examples/system_monitor.exs` in the `ex_ratatui` repo is the canonical pattern.

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

That's the whole thing. `transport: :ssh` is what flips the TUI from "render in the local TTY" to "spin up an SSH daemon and serve a fresh session per client". Under the hood `ExRatatui.App.dispatch_start/1` routes the call to `ExRatatui.SSH.Daemon` and injects `:mod` from the module name, so no separate `mod:` key is needed.

`auto_host_key: true` is the other magic line. The daemon generates an RSA host key under `priv/ssh/` on first boot (gitignored) and reuses it on every subsequent boot, so SSH clients don't see host key warnings between restarts. No wrapper module, no `ssh-keygen`, no extra files to maintain.

## Running the TUI locally for development

Iterating on the TUI itself over SSH is annoying. Every code change means quitting, restarting `mix phx.server`, and re-`ssh`'ing. The same module that the SSH daemon serves can also be rendered straight into your current terminal, no round trip. Two ways:

```sh
# 1. From an iex session that already started the app:
iex -S mix phx.server
iex> PhoenixExRatatuiExample.AdminTui.run()

# 2. Or directly, no iex:
mix run -e "PhoenixExRatatuiExample.AdminTui.run()"
```

`run/1` is a tiny convenience wrapper around `start_link/1` + `Process.monitor/1` that blocks until you press `q`. `mix run` boots the full OTP app first — `Phoenix.PubSub`, `PhoenixExRatatuiExample.Chat`, the endpoint bound to <http://localhost:4000> — so messages posted in the browser stream into the local TUI in real time over the same PubSub topic the SSH version listens on. Press `q` to quit; the BEAM exits with `run/1`, so the next invocation always starts from a clean slate.

> **Trade-off:** While the local TUI owns the terminal, the SSH daemon child is still up on port 2222. Both transports happily coexist in the same BEAM. If you don't want the listener at all during dev, set `config :phoenix_ex_ratatui_example, :ssh_admin, false` in `config/dev.exs`.

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

## See also

- **[ex_ratatui](https://github.com/mcass19/ex_ratatui)** — the underlying Elixir bindings to Rust [ratatui](https://ratatui.rs), including the [SSH transport guide](https://hexdocs.pm/ex_ratatui/ssh_transport.html).
- **[nerves_ex_ratatui_example](https://github.com/mcass19/nerves_ex_ratatui_example)** — the Nerves counterpart to this project: two TUIs registered as SSH subsystems on a Raspberry Pi via `nerves_ssh`. Same library, different deployment shape.

## License

MIT — see [LICENSE](https://github.com/mcass19/phoenix_ex_ratatui_example/blob/main/LICENSE) for details.
