defmodule PhoenixExRatatuiExample.StatsReducerTui do
  @moduledoc """
  An admin stats TUI using the **reducer runtime**.

  This module complements `PhoenixExRatatuiExample.AdminTui` (which uses
  the callback runtime). It subscribes to the same `Chat` PubSub topic
  and shows similar data, but is structured with the reducer pattern:

    * A single `update/2` handles both terminal events and mailbox
      messages.
    * Periodic stats refresh is declared via `subscriptions/1` — the
      runtime manages the timer automatically.
    * Chat stats are fetched asynchronously via `Command.async/2`, so
      the server process never blocks on a GenServer call.

  ## Transports

  Like `AdminTui`, this module is transport-agnostic. The supervision
  tree wires it up over SSH (port 2223) and Erlang distribution. See
  `PhoenixExRatatuiExample.Application` for the child specs.

  ## Running locally

      iex -S mix phx.server
      iex> PhoenixExRatatuiExample.StatsReducerTui.run()

  ## Controls

  - `1` / `2` — switch tabs (Stats / Messages)
  - `Tab` — cycle tabs
  - `q` — quit
  """

  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.{Command, Event, Frame, Layout, Layout.Rect, Style, Subscription}
  alias ExRatatui.Widgets.{Block, Paragraph, Tabs}
  alias ExRatatui.Widgets.List, as: WList
  alias PhoenixExRatatuiExample.Chat

  @tabs ~w(Stats Messages)
  @refresh_ms 1_000

  # -- Reducer callbacks --

  @impl true
  def init(_opts) do
    Chat.subscribe()
    boot_time = System.monotonic_time(:second)

    state = %{
      tab: 0,
      messages: Chat.list_messages() |> Enum.reverse(),
      stats: Chat.stats(),
      boot_time: boot_time,
      last_event_at: nil,
      notification: nil
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
  def update({:event, %Event.Key{code: "q", kind: "press"}}, state) do
    {:stop, state}
  end

  def update({:event, %Event.Key{code: code, kind: "press"}}, state)
      when code in ["1", "h", "left"] do
    {:noreply, %{state | tab: 0}}
  end

  def update({:event, %Event.Key{code: code, kind: "press"}}, state)
      when code in ["2", "l", "right"] do
    {:noreply, %{state | tab: 1}}
  end

  def update({:event, %Event.Key{code: "tab", kind: "press"}}, state) do
    {:noreply, %{state | tab: rem(state.tab + 1, length(@tabs))}}
  end

  # A new chat message arrives over PubSub.
  def update({:info, {:new_message, message}}, state) do
    # Show a brief notification, auto-dismissed after 3 seconds
    notification = "New message from #{message.user}"

    cmd =
      Command.batch([
        Command.async(fn -> Chat.stats() end, fn stats -> {:stats_refreshed, stats} end),
        Command.send_after(3_000, :clear_notification)
      ])

    {:noreply,
     %{
       state
       | messages: Enum.take([message | state.messages], 200),
         last_event_at: DateTime.utc_now(),
         notification: notification
     }, commands: [cmd]}
  end

  # Periodic stats refresh.
  def update({:info, :refresh_stats}, state) do
    cmd = Command.async(fn -> Chat.stats() end, fn stats -> {:stats_refreshed, stats} end)
    {:noreply, state, commands: [cmd], render?: false}
  end

  # Async stats result arrives.
  def update({:info, {:stats_refreshed, stats}}, state) do
    {:noreply, %{state | stats: stats}}
  end

  # Auto-dismiss notification.
  def update({:info, :clear_notification}, state) do
    {:noreply, %{state | notification: nil}}
  end

  def update(_msg, state), do: {:noreply, state}

  @impl true
  def subscriptions(_state) do
    [Subscription.interval(:stats_refresh, @refresh_ms, :refresh_stats)]
  end

  # -- Rendering helpers --

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
        title: "Phoenix + ExRatatui — Stats TUI (Reducer)"
      }
    }
  end

  defp render_body(state, _area) do
    case state.tab do
      0 -> stats_paragraph(state)
      1 -> messages_list(state)
    end
  end

  defp stats_paragraph(state) do
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
        title: "Stats"
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

    %WList{
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

  defp render_footer(state) do
    notification_text =
      case state.notification do
        nil -> ""
        text -> "  |  #{text}"
      end

    %Paragraph{
      text: " Tab/1/2: switch tabs   q: quit#{notification_text}",
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
  Starts the stats TUI (reducer runtime) in the local terminal and
  blocks until the user quits with `q`.
  """
  def run(opts \\ []) do
    {:ok, pid} = start_link(opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
