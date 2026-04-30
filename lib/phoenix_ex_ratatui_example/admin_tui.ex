defmodule PhoenixExRatatuiExample.AdminTui do
  @moduledoc """
  The admin TUI for the Phoenix app, built on ExRatatui's reducer
  runtime.

  One TUI, two tabs — served over SSH on port `2222` and over Erlang
  distribution via `ExRatatui.Distributed.Listener`. Transport-agnostic
  code: `init/1`, `render/2`, `update/2`, and `subscriptions/1` are the
  only callbacks that know about the chat state.

  ## Tabs

    * **1 · Dashboard** — rich-text overview header (node, uptime,
      totals, last message) · full-width `List` of every poster with
      their message count, names colored by the same hash-based
      palette used in the Messages tab · single-dataset `Chart` of
      messages received in the last 60 seconds, which rises with
      activity and decays as messages age out of the window.
    * **2 · Messages** — live-tail of the chat room. Each message
      renders as a `%Line{}` of colored `%Span{}`s via
      `PhoenixExRatatuiExample.Tui.MessageLine`: dim-gray timestamp,
      stable hash-based username color, white body.

  The 1-second `subscriptions/1` tick fires a single `Command.async/2`
  that snapshots `Chat.stats/0` and `Chat.per_user_counts/0`, and the
  reducer appends the delta to a rolling 60-sample history.

  ## Running locally

      iex -S mix phx.server
      iex> PhoenixExRatatuiExample.AdminTui.run()

  Or directly:

      mix run -e "PhoenixExRatatuiExample.AdminTui.run()"

  ## Controls

    * `1` / `2` — jump to a tab
    * `h` / `left`, `l` / `right` — step tabs
    * `Tab` — cycle tabs
    * `q` — quit
  """

  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.{Command, Event, Frame, Layout, Layout.Rect, Style, Subscription}
  alias ExRatatui.Text.{Line, Span}

  alias ExRatatui.Widgets.{
    Block,
    Chart,
    Paragraph,
    Tabs
  }

  alias ExRatatui.Widgets.Chart.{Axis, Dataset}
  alias ExRatatui.Widgets.List, as: WList
  alias PhoenixExRatatuiExample.Chat
  alias PhoenixExRatatuiExample.Tui.MessageLine

  @tabs ~w(Dashboard Messages)
  @refresh_ms 1_000
  @history_window 60

  # Brand colors — mirror the Phoenix + ExRatatui visual identity.
  @phoenix_orange {:rgb, 253, 79, 0}
  @exratatui_violet {:rgb, 160, 93, 244}

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
      boot_time: boot_time,
      last_event_at: nil,
      notification: nil,
      prev_total: stats.messages,
      history: %{
        rate: List.duplicate(0, @history_window),
        windowed: List.duplicate(0, @history_window)
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
      end

    [{render_tabs(state), tabs_area} | body_widgets] ++ [{render_footer(), footer_area}]
  end

  @impl true
  def update({:event, %Event.Key{code: "q", kind: "press"}}, state) do
    {:stop, state}
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

  # Periodic snapshot — fetches stats + per-user counts off the server
  # process in a single async call.
  def update({:info, :refresh_stats}, state) do
    {:noreply, state, commands: [snapshot_command()], render?: false}
  end

  def update({:info, {:stats_refreshed, {stats, per_user}}}, state) do
    delta = max(stats.messages - state.prev_total, 0)
    rate = shift(state.history.rate, delta)
    windowed = shift(state.history.windowed, Enum.sum(rate))

    {:noreply,
     %{
       state
       | stats: stats,
         per_user: per_user,
         prev_total: stats.messages,
         history: %{rate: rate, windowed: windowed}
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
        border_style: %Style{fg: :cyan},
        title: brand_title()
      }
    }
  end

  defp brand_title do
    %Line{
      spans: [
        %Span{content: " ", style: %Style{}},
        %Span{
          content: "ExRatatui",
          style: %Style{fg: @exratatui_violet, modifiers: [:bold]}
        },
        %Span{content: " + ", style: %Style{fg: :dark_gray}},
        %Span{
          content: "Phoenix ",
          style: %Style{fg: @phoenix_orange, modifiers: [:bold]}
        }
      ]
    }
  end

  defp render_footer() do
    %Paragraph{
      text:
        Line.new([
          Span.new(" Tab ", style: %Style{bg: :cyan, fg: :black, modifiers: [:bold]}),
          Span.new(" cycle ", style: %Style{fg: :dark_gray}),
          Span.new(" q ", style: %Style{bg: :red, fg: :white, modifiers: [:bold]}),
          Span.new(" quit")
        ])
    }
  end

  # -- Dashboard tab --

  defp dashboard_widgets(state, area) do
    [header_area, posters_area, chart_area] =
      Layout.split(area, :vertical, [{:length, 5}, {:min, 0}, {:length, 12}])

    [
      {overview_header(state), header_area},
      {posters_list(state), posters_area},
      {windowed_chart(state), chart_area}
    ]
  end

  defp overview_header(state) do
    uptime_seconds = System.monotonic_time(:second) - state.boot_time

    last_message =
      case state.messages do
        [] -> %Span{content: "(no messages yet)", style: %Style{fg: :dark_gray}}
        [msg | _] -> last_message_span(msg)
      end

    lines = [
      %Line{
        spans: [
          label(" Node:    "),
          value(to_string(node())),
          label("    Uptime: "),
          value(format_seconds(uptime_seconds))
        ]
      },
      %Line{
        spans: [
          label(" Messages: "),
          accent(to_string(state.stats.messages)),
          label("   Users: "),
          accent(to_string(state.stats.unique_users)),
          label("   Web: "),
          %Span{
            content: "http://localhost:4000/",
            style: %Style{fg: :cyan, modifiers: [:underlined]}
          }
        ]
      },
      %Line{spans: [label(" Last:    "), last_message]}
    ]

    %Paragraph{
      text: lines,
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue},
        title: %Span{
          content: " Overview ",
          style: %Style{fg: :blue, modifiers: [:bold]}
        }
      }
    }
  end

  defp last_message_span(msg) do
    %Span{
      content: "#{msg.user}: #{truncate(msg.body, 60)}",
      style: %Style{fg: MessageLine.user_color(msg.user)}
    }
  end

  defp label(text), do: %Span{content: text, style: %Style{fg: :dark_gray}}
  defp value(text), do: %Span{content: text, style: %Style{fg: :white, modifiers: [:bold]}}

  defp accent(text),
    do: %Span{content: text, style: %Style{fg: :blue, modifiers: [:bold]}}

  defp posters_list(state) do
    items =
      case state.per_user do
        [] ->
          [
            %Line{
              spans: [
                %Span{
                  content: " (no posts yet — chat at http://localhost:4000/) ",
                  style: %Style{fg: :dark_gray}
                }
              ]
            }
          ]

        pairs ->
          max_count = pairs |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end)
          Enum.map(pairs, &poster_line(&1, max_count))
      end

    %WList{
      items: items,
      style: %Style{fg: :white},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue},
        title: %Line{
          spans: [
            %Span{content: " Posters ", style: %Style{fg: :blue, modifiers: [:bold]}},
            %Span{content: "(#{length(state.per_user)}) ", style: %Style{fg: :dark_gray}}
          ]
        }
      }
    }
  end

  defp poster_line({user, count}, max_count) do
    name = String.pad_trailing(truncate(user, 24), 24)
    count_str = String.pad_leading(to_string(count), 4)
    bar_width = round(count / max(max_count, 1) * 24)
    bar = String.duplicate("█", bar_width)
    rest = String.duplicate("·", 24 - bar_width)

    %Line{
      spans: [
        %Span{content: " ", style: %Style{}},
        %Span{
          content: name,
          style: %Style{fg: MessageLine.user_color(user), modifiers: [:bold]}
        },
        %Span{content: " ", style: %Style{}},
        %Span{content: count_str, style: %Style{fg: :white, modifiers: [:bold]}},
        %Span{content: "  ", style: %Style{}},
        %Span{content: bar, style: %Style{fg: @exratatui_violet}},
        %Span{content: rest, style: %Style{fg: :dark_gray}}
      ]
    }
  end

  defp windowed_chart(state) do
    data = Enum.with_index(state.history.windowed, fn v, i -> {i * 1.0, v * 1.0} end)
    y_max = max(Enum.max(state.history.windowed, fn -> 0 end), 1) * 1.0

    %Chart{
      datasets: [
        %Dataset{
          name: "msgs (60s)",
          data: data,
          marker: :braille,
          graph_type: :line,
          style: %Style{fg: @exratatui_violet}
        }
      ],
      x_axis: %Axis{
        title: "seconds ago",
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
        border_style: %Style{fg: :blue},
        title: %Line{
          spans: [
            %Span{
              content: " Messages in last 60s ",
              style: %Style{fg: :blue, modifiers: [:bold]}
            }
          ]
        }
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
                  content: "(no messages yet — post one at http://localhost:4000/)",
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
        border_style: %Style{fg: :blue},
        title: %Span{
          content: " Messages (newest first) ",
          style: %Style{fg: :blue, modifiers: [:bold]}
        }
      }
    }
  end

  # -- Helpers --

  defp snapshot_command do
    Command.async(
      fn -> {Chat.stats(), Chat.per_user_counts()} end,
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
  Starts the admin TUI in the local terminal and blocks until the
  user quits with `q`.
  """
  def run(opts \\ []) do
    {:ok, pid} = start_link(opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
