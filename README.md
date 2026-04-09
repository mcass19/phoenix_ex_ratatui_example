# Phoenix + ExRatatui Example

A minimal Phoenix 1.8 application with an **admin TUI you reach over SSH**.
The web app is a tiny chat room. Everything posted in the browser appears
live in any terminal connected to the SSH admin TUI — no special client,
no extra port forwarding, no agent on the box.

The point of this repo is to show that any Phoenix or LiveView codebase
can ship a real terminal admin dashboard with about 30 lines of code,
using [`ExRatatui`](https://github.com/mcass19/ex_ratatui)'s SSH transport.

## What you get

- **`/`** — a public chat room LiveView (`PhoenixExRatatuiExampleWeb.ChatLive`).
  Pick a username, post a message, watch others post in real time.
- **`ssh -p 2222 admin@localhost`** — drops you straight into a TUI
  (`PhoenixExRatatuiExample.AdminTui`) that subscribes to the same
  `Phoenix.PubSub` topic as the LiveView. New chat messages stream in
  immediately. Two tabs:
  - **Overview** — node, BEAM uptime, message count, last activity.
  - **Messages** — live tail of the room.
- **No global TTY required.** Each SSH client gets its own isolated
  session. Multiple ops engineers can be in the TUI simultaneously
  without stepping on each other.

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

> **Note:** The `mix setup` step pulls in `ex_ratatui` as a path
> dependency for now. Once the SSH transport ships on Hex, the dep
> in `mix.exs` will switch back to `{:ex_ratatui, "~> X.Y"}` and the
> `rustler` host-only dep will be removed.

## How the admin TUI is wired up

Two pieces:

### 1. The `ExRatatui.App` module

[`lib/phoenix_ex_ratatui_example/admin_tui.ex`](lib/phoenix_ex_ratatui_example/admin_tui.ex)
implements `mount/1`, `render/2`, `handle_event/2`, and `handle_info/2`.
It subscribes to `PhoenixExRatatuiExample.Chat`'s PubSub topic in `mount/1`,
re-renders whenever a `{:new_message, _}` arrives, and quits on `q`.
Standard ExRatatui app — nothing in it knows it's being served over SSH.

### 2. The supervision tree

[`lib/phoenix_ex_ratatui_example/application.ex`](lib/phoenix_ex_ratatui_example/application.ex)
adds `ExRatatui.SSH.Daemon` directly as a child, alongside
`Phoenix.PubSub`, the chat GenServer, and the endpoint:

```elixir
children = [
  PhoenixExRatatuiExampleWeb.Telemetry,
  {Phoenix.PubSub, name: PhoenixExRatatuiExample.PubSub},
  PhoenixExRatatuiExample.Chat,
  {ExRatatui.SSH.Daemon,
   mod: PhoenixExRatatuiExample.AdminTui,
   port: 2222,
   auto_host_key: true,
   auth_methods: ~c"password",
   user_passwords: [{~c"admin", ~c"admin"}]},
  PhoenixExRatatuiExampleWeb.Endpoint
]
```

That's it. `auto_host_key: true` is the magic line — the daemon
generates an RSA host key under `priv/ssh/` on first boot (gitignored)
and reuses it on every subsequent boot, so SSH clients don't see host
key warnings between restarts. No wrapper module, no `ssh-keygen`, no
extra files to maintain.

## Adapting it to your own Phoenix app

1. Add `{:ex_ratatui, "~> X.Y"}` to `mix.exs`.
2. Drop the admin TUI module above into your project (or write your own).
3. Add the `ExRatatui.SSH.Daemon` child spec to your `application.ex`,
   pointing `:mod` at your TUI module.
4. Replace the chat-specific bits with whatever you want to expose
   in the terminal — recently failing Oban jobs, queue depth, live
   trace of an LV mount, on-call paging stats. Anything you can
   subscribe to over PubSub or query from a context, you can render
   in the TUI.
5. **Before shipping to anything that isn't your laptop**, swap the
   dev password for SSH key auth and pin `:system_dir` to a directory
   under your own configuration management — see
   [`ExRatatui.SSH.Daemon`](https://hexdocs.pm/ex_ratatui/ExRatatui.SSH.Daemon.html)
   for the full options list. `auto_host_key: true` is great for
   demos and internal tools but it is not production-grade host-key
   management.

## Configuration

Disable the admin daemon entirely (e.g. in test):

```elixir
# config/test.exs
config :phoenix_ex_ratatui_example, :ssh_admin, false
```

Override its options (anything you set here wins over the defaults
baked into `application.ex`):

```elixir
# config/runtime.exs
config :phoenix_ex_ratatui_example, :ssh_admin_opts,
  port: 2222,
  auth_methods: ~c"publickey",
  user_dir: ~c"/etc/ssh/users",
  system_dir: ~c"/etc/ssh"
```

Passing `:system_dir` automatically disables `:auto_host_key`, so you
can manage host keys explicitly in production.

## Tests

```sh
mix test
```

Coverage:

- `Chat` — post / list / stats / broadcast (`test/phoenix_ex_ratatui_example/chat_test.exs`)
- `AdminTui` — `mount/1`, `render/2`, `handle_event/2`, `handle_info/2`
  plus an end-to-end render through `ExRatatui.Server`'s test backend
  (`test/phoenix_ex_ratatui_example/admin_tui_test.exs`)
- `ChatLive` — render, submit, rename, flash error
  (`test/phoenix_ex_ratatui_example_web/live/chat_live_test.exs`)

The suite never opens a real SSH listener — `config/test.exs` sets
`ssh_admin: false`. The admin TUI's render path is exercised through
ExRatatui's headless test backend instead.

## License

MIT.
