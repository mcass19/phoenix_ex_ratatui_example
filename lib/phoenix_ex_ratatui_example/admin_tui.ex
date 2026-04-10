defmodule PhoenixExRatatuiExample.AdminTui do
  @moduledoc """
  An admin TUI for the Phoenix app, built on `ExRatatui.App`.

  Two tabs:

    * **Overview** — connected runtime stats (BEAM uptime, message
      count, recent activity rate, last sender) plus a footer with
      key bindings.
    * **Messages** — live tail of the chat room. New messages stream
      in via the `PhoenixExRatatuiExample.Chat` PubSub topic — the
      same topic the browser LiveView subscribes to.

  ## How it gets to your terminal

  The supervision tree starts an `ExRatatui.SSH.Daemon` with
  `auto_host_key: true`, which generates an RSA host key under
  `priv/ssh/` on first boot and exposes this app module on port
  `2222`. Any user with the dev credentials runs:

      ssh -p 2222 admin@localhost

  and gets their own private TUI session against the running
  Phoenix node. See `PhoenixExRatatuiExample.Application` for the
  child spec.

  ## Local dev mode

  For fast iteration on the TUI itself you can render it in your
  current terminal instead of going through SSH. Boot the Phoenix
  app the usual way and call `run/1`:

      # From an iex session that already started Phoenix:
      iex -S mix phx.server
      iex> PhoenixExRatatuiExample.AdminTui.run()

      # Or directly, no iex:
      mix run -e "PhoenixExRatatuiExample.AdminTui.run()"

  Both flows reuse the same `Phoenix.PubSub` topic the SSH session
  subscribes to, so messages posted in the browser stream into the
  local TUI in real time. Press `q` to quit; `run/1` blocks until
  the TUI process exits, so the BEAM shuts down cleanly with it.

  ## Test mode

  When started with `test_mode: {w, h}`, the underlying server uses
  `ExRatatui`'s headless test backend instead of a real terminal —
  see `test/phoenix_ex_ratatui_example/admin_tui_test.exs`.
  """

  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Frame
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, List, Paragraph, Tabs}
  alias PhoenixExRatatuiExample.Chat

  @tabs ~w(Overview Messages)

  @impl true
  def mount(_opts) do
    Chat.subscribe()
    boot_time = System.monotonic_time(:second)

    state = %{
      tab: 0,
      messages: Chat.list_messages() |> Enum.reverse(),
      stats: Chat.stats(),
      boot_time: boot_time,
      last_event_at: nil
    }

    {:ok, state}
  end

  @impl true
  def render(state, %Frame{width: w, height: h}) do
    area = %Rect{x: 0, y: 0, width: w, height: h}

    [tabs_area, body_area, footer_area] =
      Layout.split(area, :vertical, [{:length, 3}, {:min, 0}, {:length, 3}])

    [
      {render_tabs(state), tabs_area},
      {render_body(state, body_area), body_area},
      {render_footer(state), footer_area}
    ]
  end

  @impl true
  def handle_event(%Event.Key{code: "q", kind: "press"}, state) do
    {:stop, state}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state)
      when code in ["1", "h", "left"] do
    {:noreply, %{state | tab: 0}}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state)
      when code in ["2", "l", "right"] do
    {:noreply, %{state | tab: 1}}
  end

  def handle_event(%Event.Key{code: "tab", kind: "press"}, state) do
    {:noreply, %{state | tab: rem(state.tab + 1, length(@tabs))}}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_info({:new_message, message}, state) do
    {:noreply,
     %{
       state
       | messages: Enum.take([message | state.messages], 200),
         stats: Chat.stats(),
         last_event_at: DateTime.utc_now()
     }}
  end

  def handle_info({:presence, _count}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  ## Rendering helpers

  defp render_tabs(state) do
    %Tabs{
      titles: @tabs,
      selected: state.tab,
      style: %Style{fg: :gray},
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray},
        title: "Phoenix + ExRatatui — Admin TUI"
      }
    }
  end

  defp render_body(state, _area) do
    case state.tab do
      0 -> overview_paragraph(state)
      1 -> messages_list(state)
    end
  end

  defp overview_paragraph(state) do
    uptime_seconds = System.monotonic_time(:second) - state.boot_time

    last_event =
      case state.last_event_at do
        nil -> "—"
        %DateTime{} = dt -> Calendar.strftime(dt, "%H:%M:%S UTC")
      end

    last_message =
      case state.messages do
        [] -> "(no messages yet)"
        [msg | _] -> "#{msg.user}: #{truncate(msg.body, 60)}"
      end

    text =
      """

        Node:              #{node()}
        BEAM uptime:       #{format_seconds(uptime_seconds)}

        Total messages:    #{state.stats.messages}
        Unique users:      #{state.stats.unique_users}

        Last activity:     #{last_event}
        Last message:      #{last_message}

        Live LiveView URL: http://localhost:4000/
      """

    %Paragraph{
      text: text,
      style: %Style{fg: :white},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan},
        title: "Overview"
      }
    }
  end

  defp messages_list(state) do
    items =
      case state.messages do
        [] ->
          ["(no messages yet — post one in the browser at http://localhost:4000/)"]

        messages ->
          messages
          |> Enum.take(50)
          |> Enum.map(fn msg ->
            "[#{Calendar.strftime(msg.inserted_at, "%H:%M:%S")}] " <>
              "#{msg.user}: #{truncate(msg.body, 80)}"
          end)
      end

    %List{
      items: items,
      style: %Style{fg: :white},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan},
        title: "Messages (newest first)"
      }
    }
  end

  defp render_footer(_state) do
    %Paragraph{
      text: " Tab/1/2: switch tabs   q: quit",
      style: %Style{fg: :dark_gray},
      block: %Block{
        borders: [:top],
        border_style: %Style{fg: :dark_gray}
      }
    }
  end

  defp truncate(string, max) when is_binary(string) do
    if String.length(string) > max do
      String.slice(string, 0, max - 1) <> "…"
    else
      string
    end
  end

  @doc false
  def format_seconds(seconds) when seconds < 60, do: "#{seconds}s"

  def format_seconds(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  def format_seconds(seconds) do
    h = div(seconds, 3600)
    rest = rem(seconds, 3600)
    "#{h}h #{div(rest, 60)}m"
  end

  ## Local dev entry point

  @doc """
  Starts the admin TUI in the local terminal and blocks until the
  user quits with `q`.

  Accepts the same options as `start_link/1`. Intended for `iex -S
  mix phx.server` and `mix run -e "..."`-style invocations — see the
  module doc for examples.
  """
  def run(opts \\ []) do
    {:ok, pid} = start_link(opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
