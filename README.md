# Phoenix ExRatatui Example

A minimal Phoenix application with an **admin and stats TUI you reach over SSH or Erlang distribution**. The web app is a tiny chat room. Everything posted in the browser appears live in any terminal connected to the TUI — no special client, no extra port forwarding, no agent on the box.

The point of this repo is to show that any Phoenix or LiveView codebase can easily ship a real terminal UI, using [`ExRatatui`](https://github.com/mcass19/ex_ratatui)'s SSH and distribution transports.

![Phoenix ExRatatui Demo](https://raw.githubusercontent.com/mcass19/phoenix_ex_ratatui_example/main/assets/phoenix_demo.gif)

## What you get

- **`/`** — a public chat room LiveView (`PhoenixExRatatuiExampleWeb.ChatLive`). Pick a username, post a message, watch others post in real time.
- **`ssh -p 2222 admin@localhost`** — the **Admin TUI** (`AdminTui`, **callback runtime**). Two tabs: Overview (two side-by-side panels driven by `ExRatatui.Focus` — `Tab`/`Shift+Tab` rotates which panel's border lights up) and Messages (rich-text list where every username gets a stable hash-based color via `Span`/`Line`).
- **`ssh -p 2223 admin@localhost`** — the **Stats TUI** (`StatsReducerTui`, **reducer runtime**). A real-time dashboard driven by a 1-second `subscriptions/1` tick. Three tabs: Dashboard (a `Sparkline` of messages/tick, a horizontal `BarChart` of top posters, and a two-dataset `Chart` of totals over the last 60s), Messages (same rich-text renderer as AdminTui), and Calendar (a monthly `Calendar` widget heatmap'd by per-day message counts).
- **`ExRatatui.Distributed.attach/2`** — from any named BEAM node sharing the same cookie, attach to either TUI over Erlang distribution. Same isolated-session model as SSH, but no daemon, no host keys — just BEAM-to-BEAM.
- **No global TTY required.** Each SSH or distribution client gets its own isolated session. Multiple can be in the TUI simultaneously without stepping on each other.

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

# Terminal-side: watch them stream into the TUIs over SSH
ssh -p 2222 admin@localhost           # Admin TUI (callback runtime), password: admin
ssh -p 2223 admin@localhost           # Stats TUI (reducer runtime), password: admin
```

Or try distribution instead — start Phoenix as a named node:

```sh
iex --sname phoenix --cookie demo -S mix phx.server
```

Then from a second terminal (same project directory):

```sh
iex --sname client --cookie demo -S mix run --no-start
iex> ExRatatui.Distributed.attach(:"phoenix@yourmachine", PhoenixExRatatuiExample.AdminTui)
iex> ExRatatui.Distributed.attach(:"phoenix@yourmachine", PhoenixExRatatuiExample.StatsReducerTui)
```

`--no-start` loads all compiled code (including the `ExRatatui` NIF) without booting the Phoenix application, so there's no port conflict with the first terminal. Replace `yourmachine` with the short hostname shown in the first terminal's IEx prompt (the part after `@` in `phoenix@yourmachine`).

Quit the TUI with `q`. Quit Phoenix with `Ctrl+C` twice.

## How the TUIs are wired up

### 1. The `ExRatatui.App` modules

**Admin TUI (callback runtime)** — [`lib/phoenix_ex_ratatui_example/admin_tui.ex`](lib/phoenix_ex_ratatui_example/admin_tui.ex) implements `mount/1`, `render/2`, `handle_event/2`, and `handle_info/2`. Subscribes to `PhoenixExRatatuiExample.Chat`'s PubSub topic in `mount/1`, re-renders whenever a `{:new_message, _}` arrives. On the Overview tab it showcases:

- **`ExRatatui.Focus`** — tiny focus-ring state machine that tracks which panel owns keystrokes. `Tab`/`Shift+Tab` rotates focus; `Focus.focused?/2` drives the border-style toggle without `Focus` ever touching widget structs.
- **Rich-text `Span`/`Line`** — the recent-messages panel (and the full Messages tab) renders each post as a `%Line{}` of color-coded spans via [`Tui.MessageLine`](lib/phoenix_ex_ratatui_example/tui/message_line.ex): dim-gray timestamp, hash-derived per-user color for the name, white body.

**Stats TUI (reducer runtime)** — [`lib/phoenix_ex_ratatui_example/stats_reducer_tui.ex`](lib/phoenix_ex_ratatui_example/stats_reducer_tui.ex) uses `ExRatatui.App, runtime: :reducer` — all messages flow through a single `update/2`. The 1-second `subscriptions/1` tick fires an async command that snapshots `Chat.stats/0`, `Chat.per_user_counts/0`, and `Chat.per_day_counts/0` in one call; the reducer appends to a 60-sample rolling history and hands the whole thing to the widgets. It showcases:

- **`ExRatatui.Widgets.Sparkline`** — messages per tick over the last 60s, auto-scaled.
- **`ExRatatui.Widgets.BarChart`** — horizontal chart of the top 5 posters, each bar colored by the same hash used for rich-text usernames.
- **`ExRatatui.Widgets.Chart`** — two-dataset line chart of cumulative messages and unique users over the history window, with axes and legend.
- **`ExRatatui.Widgets.Calendar`** — monthly heatmap on the Calendar tab; each day gets a style bucketed on its message count.
- **`Subscription.interval/3`** — periodic tick declared, not hand-rolled with `Process.send_after`.
- **`Command.async/2` + `Command.send_after/2` + `Command.batch/1`** — snapshotting data off the server process, scheduling the notification auto-dismiss, and grouping both in a single `{:new_message, _}` return.

Both modules subscribe to the same PubSub topic and share the same `Chat` GenServer — they just structure the handling differently and render very different views of it.

### 2. The supervision tree

[`lib/phoenix_ex_ratatui_example/application.ex`](lib/phoenix_ex_ratatui_example/application.ex) starts both TUIs alongside `Phoenix.PubSub`, the chat GenServer, and the endpoint:

```elixir
children = [
  PhoenixExRatatuiExampleWeb.Telemetry,
  {Phoenix.PubSub, name: PhoenixExRatatuiExample.PubSub},
  PhoenixExRatatuiExample.Chat,
  # Admin TUI (callback runtime) — SSH on port 2222
  ssh_admin_child(),
  distributed_admin_child(),
  # Stats TUI (reducer runtime) — SSH on port 2223
  ssh_stats_reducer_child(),
  distributed_stats_reducer_child(),
  PhoenixExRatatuiExampleWeb.Endpoint
]
```

`transport: :ssh` is what flips a TUI from "render in the local TTY" to "spin up an SSH daemon and serve a fresh session per client". Each TUI gets its own SSH port so both daemons coexist.

`auto_host_key: true` generates an RSA host key under `priv/ssh/` on first boot (gitignored) and reuses it on every subsequent boot. No wrapper module, no `ssh-keygen`, no extra files to maintain.

### 3. The distribution listeners

Both TUIs also have `ExRatatui.Distributed.Listener`s. Each attaching node gets its own isolated TUI session — the same model as SSH, but over Erlang distribution instead of an SSH channel. No NIF is loaded on the Phoenix node for distribution sessions; widget structs travel as plain BEAM terms and the attaching node renders them locally.

All transports share the same app modules — `mount/1`/`init/1`, `render/2`, and the event handlers are transport-agnostic.

## Running the TUIs locally for development

Iterating on a TUI over SSH is annoying. Every code change means quitting, restarting `mix phx.server`, and re-`ssh`'ing. The same modules the SSH daemons serve can also be rendered straight into your current terminal, no round trip:

```sh
# From an iex session that already started the app:
iex -S mix phx.server
iex> PhoenixExRatatuiExample.AdminTui.run()          # callback runtime
iex> PhoenixExRatatuiExample.StatsReducerTui.run()    # reducer runtime

# Or directly, no iex:
mix run -e "PhoenixExRatatuiExample.AdminTui.run()"
mix run -e "PhoenixExRatatuiExample.StatsReducerTui.run()"
```

`run/1` is a tiny convenience wrapper around `start_link/1` + `Process.monitor/1` that blocks until you press `q`. `mix run` boots the full OTP app first — `Phoenix.PubSub`, `PhoenixExRatatuiExample.Chat`, the endpoint bound to <http://localhost:4000> — so messages posted in the browser stream into the local TUI in real time over the same PubSub topic the SSH version listens on. Press `q` to quit; the BEAM exits with `run/1`, so the next invocation always starts from a clean slate.

> **Trade-off:** While the local TUI owns the terminal, the SSH daemon children are still up on ports 2222 and 2223. All transports happily coexist in the same BEAM. If you don't want the listeners at all during dev, set the relevant config keys to `false` in `config/dev.exs`.

## Configuration

Disable TUI daemons entirely (e.g. in test):

```elixir
# config/test.exs
config :phoenix_ex_ratatui_example, :ssh_admin, false
config :phoenix_ex_ratatui_example, :distributed_admin, false
config :phoenix_ex_ratatui_example, :ssh_stats_reducer, false
config :phoenix_ex_ratatui_example, :distributed_stats_reducer, false
```

Override SSH options (anything you set here wins over the defaults baked into `application.ex`):

```elixir
# config/runtime.exs
config :phoenix_ex_ratatui_example, :ssh_admin_opts,
  port: 2222,
  auth_methods: ~c"publickey",
  user_dir: ~c"/etc/ssh/users",
  system_dir: ~c"/etc/ssh"

config :phoenix_ex_ratatui_example, :ssh_stats_reducer_opts,
  port: 2223
```

Passing `:system_dir` automatically disables `:auto_host_key`, so you can manage host keys explicitly in production.

Override distribution options:

```elixir
config :phoenix_ex_ratatui_example, :distributed_admin_opts,
  app_opts: [some_key: "value"]  # merged into every session's mount/1 opts

config :phoenix_ex_ratatui_example, :distributed_stats_reducer_opts,
  app_opts: [some_key: "value"]
```

## See also

- **[ex_ratatui](https://github.com/mcass19/ex_ratatui)** — the underlying Elixir bindings to Rust [ratatui](https://ratatui.rs), including the [SSH transport guide](https://hexdocs.pm/ex_ratatui/ssh_transport.html) and [distribution transport guide](https://hexdocs.pm/ex_ratatui/distributed_transport.html).
- **[nerves_ex_ratatui_example](https://github.com/mcass19/nerves_ex_ratatui_example)** — the Nerves counterpart to this project: two TUIs on a Raspberry Pi, reachable over SSH subsystems and Erlang distribution. Same library, different deployment shape.

## License

MIT — see [LICENSE](https://github.com/mcass19/phoenix_ex_ratatui_example/blob/main/LICENSE) for details.
