defmodule PhoenixExRatatuiExample.StatsReducerTui do
  @moduledoc """
  An admin stats **dashboard** using the reducer runtime.

  Complements `PhoenixExRatatuiExample.AdminTui` (callback runtime) by
  leaning on every new visual widget ExRatatui 0.8 ships with. Each
  `subscriptions/1` tick fires a single async command that snapshots
  chat data; the reducer updates a 60-sample rolling history and lets
  the widgets render themselves off state.

  ## Tabs

    * **1 · Dashboard** — info header · `Sparkline` of messages/tick
      over the last 60s · horizontal `BarChart` of top posters · two-
      dataset `Chart` of totals over time.
    * **2 · Messages** — rich-text `List` with per-user colored
      usernames (stable hash-based color) rendered via
      `PhoenixExRatatuiExample.Tui.MessageLine`.
    * **3 · Calendar** — monthly heatmap; each day styled according
      to its message count bucket.

  ## Transports

  Transport-agnostic. Supervision tree wires this up over SSH (port
  2223) and Erlang distribution. See
  `PhoenixExRatatuiExample.Application`.

  ## Running locally

      iex -S mix phx.server
      iex> PhoenixExRatatuiExample.StatsReducerTui.run()

  ## Controls

    * `1` / `2` / `3` — switch tabs
    * `Tab` — cycle tabs
    * `q` — quit
  """

  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.{Command, Event, Frame, Layout, Layout.Rect, Style, Subscription}
  alias ExRatatui.Text.{Line, Span}

  alias ExRatatui.Widgets.{
    Bar,
    BarChart,
    Block,
    Chart,
    Paragraph,
    Sparkline,
    Tabs
  }

  alias ExRatatui.Widgets.Calendar, as: CalendarWidget

  alias ExRatatui.Widgets.Chart.{Axis, Dataset}
  alias ExRatatui.Widgets.List, as: WList
  alias PhoenixExRatatuiExample.Chat
  alias PhoenixExRatatuiExample.Tui.MessageLine

  @tabs ~w(Dashboard Messages Calendar)
  @refresh_ms 1_000
  @history_window 60
  @top_posters 5

  # -- Reducer callbacks --

  @impl true
  def init(_opts) do
    Chat.subscribe()
    boot_time = System.monotonic_time(:second)
    stats = Chat.stats()

    state = %{
      tab: 0,
      messages: Chat.list_messages() |> Enum.reverse(),
      stats: stats,
      per_user: Chat.per_user_counts(),
      per_day: Chat.per_day_counts(),
      boot_time: boot_time,
      last_event_at: nil,
      notification: nil,
      prev_total: stats.messages,
      history: %{
        total_msgs: List.duplicate(stats.messages, @history_window),
        unique_users: List.duplicate(stats.unique_users, @history_window),
        rate: List.duplicate(0, @history_window)
      }
    }

    {:ok, state}
  end

  @impl true
  def render(state, %Frame{width: w, height: h}) do
    area = %Rect{x: 0, y: 0, width: w, height: h}

    [tabs_area, body_area, footer_area] =
      Layout.split(area, :vertical, [{:length, 3}, {:min, 0}, {:length, 3}])

    body_widgets =
      case state.tab do
        0 -> dashboard_widgets(state, body_area)
        1 -> [{messages_list(state), body_area}]
        2 -> [{calendar_widget(state), body_area}]
      end

    [{render_tabs(state), tabs_area} | body_widgets] ++ [{render_footer(state), footer_area}]
  end

  @impl true
  def update({:event, %Event.Key{code: "q", kind: "press"}}, state) do
    {:stop, state}
  end

  def update({:event, %Event.Key{code: "1", kind: "press"}}, state),
    do: {:noreply, %{state | tab: 0}}

  def update({:event, %Event.Key{code: "2", kind: "press"}}, state),
    do: {:noreply, %{state | tab: 1}}

  def update({:event, %Event.Key{code: "3", kind: "press"}}, state),
    do: {:noreply, %{state | tab: 2}}

  def update({:event, %Event.Key{code: code, kind: "press"}}, state)
      when code in ["l", "right"] do
    {:noreply, %{state | tab: min(state.tab + 1, length(@tabs) - 1)}}
  end

  def update({:event, %Event.Key{code: code, kind: "press"}}, state)
      when code in ["h", "left"] do
    {:noreply, %{state | tab: max(state.tab - 1, 0)}}
  end

  def update({:event, %Event.Key{code: "tab", kind: "press"}}, state) do
    {:noreply, %{state | tab: rem(state.tab + 1, length(@tabs))}}
  end

  # A new chat message arrives over PubSub.
  def update({:info, {:new_message, message}}, state) do
    cmd =
      Command.batch([
        snapshot_command(),
        Command.send_after(3_000, :clear_notification)
      ])

    {:noreply,
     %{
       state
       | messages: Enum.take([message | state.messages], 200),
         last_event_at: DateTime.utc_now(),
         notification: "New message from #{message.user}"
     }, commands: [cmd]}
  end

  # Periodic snapshot — fetches stats, per-user counts, and per-day
  # counts in a single async call so the server process never blocks.
  def update({:info, :refresh_stats}, state) do
    {:noreply, state, commands: [snapshot_command()], render?: false}
  end

  def update({:info, {:stats_refreshed, {stats, per_user, per_day}}}, state) do
    delta = max(stats.messages - state.prev_total, 0)

    history = %{
      total_msgs: shift(state.history.total_msgs, stats.messages),
      unique_users: shift(state.history.unique_users, stats.unique_users),
      rate: shift(state.history.rate, delta)
    }

    {:noreply,
     %{
       state
       | stats: stats,
         per_user: per_user,
         per_day: per_day,
         prev_total: stats.messages,
         history: history
     }}
  end

  def update({:info, :clear_notification}, state) do
    {:noreply, %{state | notification: nil}}
  end

  def update(_msg, state), do: {:noreply, state}

  @impl true
  def subscriptions(_state) do
    [Subscription.interval(:stats_refresh, @refresh_ms, :refresh_stats)]
  end

  # -- Dashboard layout --

  defp dashboard_widgets(state, area) do
    [header_area, middle_area, bottom_area] =
      Layout.split(area, :vertical, [{:length, 6}, {:min, 0}, {:length, 10}])

    [left_area, right_area] =
      Layout.split(middle_area, :horizontal, [{:percentage, 50}, {:percentage, 50}])

    [
      {header_paragraph(state), header_area},
      {rate_sparkline(state), left_area},
      {top_posters_bar_chart(state), right_area},
      {totals_chart(state), bottom_area}
    ]
  end

  defp header_paragraph(state) do
    uptime_seconds = System.monotonic_time(:second) - state.boot_time

    last_message =
      case state.messages do
        [] -> "(no messages yet)"
        [msg | _] -> "#{msg.user}: #{truncate(msg.body, 50)}"
      end

    text = """
     Node: #{node()}   Uptime: #{format_seconds(uptime_seconds)}   Messages: #{state.stats.messages}   Users: #{state.stats.unique_users}
     Last: #{last_message}
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

  defp rate_sparkline(state) do
    max_rate = Enum.max(state.history.rate, fn -> 0 end)

    %Sparkline{
      data: state.history.rate,
      max: max(max_rate, 1),
      style: %Style{fg: :green},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray},
        title: "Messages per tick  (last #{@history_window}s)"
      }
    }
  end

  defp top_posters_bar_chart(state) do
    bars =
      state.per_user
      |> Enum.take(@top_posters)
      |> Enum.map(fn {user, count} ->
        %Bar{
          label: user,
          value: count,
          style: %Style{fg: MessageLine.user_color(user), modifiers: [:bold]}
        }
      end)

    %BarChart{
      data: bars,
      direction: :horizontal,
      bar_width: 1,
      bar_gap: 0,
      bar_style: %Style{fg: :cyan},
      value_style: %Style{fg: :white, modifiers: [:bold]},
      label_style: %Style{fg: :white},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray},
        title: "Top #{@top_posters} posters"
      }
    }
  end

  defp totals_chart(state) do
    msg_data = Enum.with_index(state.history.total_msgs, fn v, i -> {i * 1.0, v * 1.0} end)

    user_data =
      Enum.with_index(state.history.unique_users, fn v, i -> {i * 1.0, v * 1.0} end)

    msg_max = Enum.max(state.history.total_msgs, fn -> 0 end)
    user_max = Enum.max(state.history.unique_users, fn -> 0 end)
    y_max = max(max(msg_max, user_max), 1) * 1.0

    %Chart{
      datasets: [
        %Dataset{
          name: "messages",
          data: msg_data,
          marker: :braille,
          graph_type: :line,
          style: %Style{fg: :cyan}
        },
        %Dataset{
          name: "users",
          data: user_data,
          marker: :braille,
          graph_type: :line,
          style: %Style{fg: :magenta}
        }
      ],
      x_axis: %Axis{
        title: "ticks ago",
        bounds: {0.0, (@history_window - 1) * 1.0},
        labels: ["-#{@history_window}s", "-#{div(@history_window, 2)}s", "now"],
        labels_alignment: :center,
        style: %Style{fg: :dark_gray}
      },
      y_axis: %Axis{
        title: "count",
        bounds: {0.0, y_max},
        labels: ["0", Integer.to_string(trunc(y_max))],
        style: %Style{fg: :dark_gray}
      },
      legend_position: :top_right,
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray},
        title: "Totals over time"
      }
    }
  end

  # -- Messages tab --

  defp messages_list(state) do
    items =
      case state.messages do
        [] ->
          [
            %Line{
              spans: [
                %Span{
                  content:
                    "(no messages yet — post one in the browser at http://localhost:4000/)",
                  style: %Style{fg: :dark_gray}
                }
              ]
            }
          ]

        messages ->
          messages
          |> Enum.take(50)
          |> Enum.map(&MessageLine.render(&1, max_body: 80))
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

  # -- Calendar tab --

  defp calendar_widget(state) do
    today = Date.utc_today()

    events =
      Map.new(state.per_day, fn {date, count} -> {date, count_style(count)} end)

    %CalendarWidget{
      display_date: today,
      events: events,
      default_style: %Style{fg: :dark_gray},
      header_style: %Style{fg: :cyan, modifiers: [:bold]},
      weekday_style: %Style{fg: :gray},
      show_surrounding: %Style{fg: :dark_gray},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan},
        title: "Activity — #{Calendar.strftime(today, "%B %Y")}"
      }
    }
  end

  defp count_style(count) when count >= 6, do: %Style{fg: :black, bg: :green, modifiers: [:bold]}
  defp count_style(count) when count >= 2, do: %Style{fg: :green, modifiers: [:bold]}
  defp count_style(count) when count >= 1, do: %Style{fg: :light_green}
  defp count_style(_), do: %Style{}

  # -- Top-level chrome --

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

  defp render_footer(state) do
    notification_text =
      case state.notification do
        nil -> ""
        text -> "  |  #{text}"
      end

    %Paragraph{
      text: " Tab/1/2/3: switch tabs   q: quit#{notification_text}",
      style: %Style{fg: :dark_gray},
      block: %Block{
        borders: [:top],
        border_style: %Style{fg: :dark_gray}
      }
    }
  end

  # -- Helpers --

  defp snapshot_command do
    Command.async(
      fn -> {Chat.stats(), Chat.per_user_counts(), Chat.per_day_counts()} end,
      fn payload -> {:stats_refreshed, payload} end
    )
  end

  defp shift(list, new_val) when is_list(list) do
    tl(list) ++ [new_val]
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
