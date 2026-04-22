defmodule PhoenixExRatatuiExample.AdminTui do
  @moduledoc """
  Admin TUI for the Phoenix app, built on the callback runtime.

  ## Tabs

    * **Overview** — two side-by-side panels with a focus ring:
      connected runtime stats on the left and a rich-text recent-
      messages preview on the right. `Tab` / `Shift+Tab` rotate focus;
      the focused panel's border turns cyan. Drives
      `ExRatatui.Focus` directly — no LiveComponent-style machinery.
    * **Messages** — live tail of the chat room. New messages stream
      in via the `PhoenixExRatatuiExample.Chat` PubSub topic (the same
      topic the browser LiveView subscribes to) and render through
      `PhoenixExRatatuiExample.Tui.MessageLine` for per-user color.

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

  Iterating on a TUI over SSH is annoying. Render it straight into
  your current terminal instead:

      iex -S mix phx.server
      iex> PhoenixExRatatuiExample.AdminTui.run()

      # Or directly, no iex:
      mix run -e "PhoenixExRatatuiExample.AdminTui.run()"

  Both flows reuse the same `Phoenix.PubSub` topic the SSH session
  subscribes to, so messages posted in the browser stream in live.
  Press `q` to quit.

  ## Test mode

  When started with `test_mode: {w, h}`, the underlying server uses
  `ExRatatui`'s headless test backend — see
  `test/phoenix_ex_ratatui_example/admin_tui_test.exs`.
  """

  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Focus
  alias ExRatatui.Frame
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Tabs}
  alias ExRatatui.Widgets.List, as: WList
  alias PhoenixExRatatuiExample.Chat
  alias PhoenixExRatatuiExample.Tui.MessageLine

  @tabs ~w(Overview Messages)
  @overview_panels [:stats, :recent]

  @impl true
  def mount(_opts) do
    Chat.subscribe()
    boot_time = System.monotonic_time(:second)

    state = %{
      tab: 0,
      messages: Chat.list_messages() |> Enum.reverse(),
      stats: Chat.stats(),
      boot_time: boot_time,
      last_event_at: nil,
      focus: Focus.new(@overview_panels)
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
        0 -> overview_widgets(state, body_area)
        1 -> [{messages_list(state), body_area}]
      end

    [{render_tabs(state), tabs_area} | body_widgets] ++ [{render_footer(state), footer_area}]
  end

  @impl true
  def handle_event(%Event.Key{code: "q", kind: "press"}, state) do
    {:stop, state}
  end

  # Tab / Shift+Tab only cycle panel focus while the Overview tab is
  # active — on the Messages tab they switch tabs like the other
  # shortcuts. We route to Focus.handle_key/2 first; if it consumed
  # the event we stop, otherwise we fall through to tab navigation.
  def handle_event(%Event.Key{code: code, kind: "press"} = key, %{tab: 0} = state)
      when code in ["tab", "back_tab"] do
    {focus, _} = Focus.handle_key(state.focus, key)
    {:noreply, %{state | focus: focus}}
  end

  def handle_event(%Event.Key{code: "1", kind: "press"}, state) do
    {:noreply, %{state | tab: 0}}
  end

  def handle_event(%Event.Key{code: "2", kind: "press"}, state) do
    {:noreply, %{state | tab: 1}}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state)
      when code in ["h", "left"] do
    {:noreply, %{state | tab: max(state.tab - 1, 0)}}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state)
      when code in ["l", "right"] do
    {:noreply, %{state | tab: min(state.tab + 1, length(@tabs) - 1)}}
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

  defp overview_widgets(state, area) do
    [left_area, right_area] =
      Layout.split(area, :horizontal, [{:percentage, 50}, {:percentage, 50}])

    [
      {stats_panel(state), left_area},
      {recent_messages_panel(state), right_area}
    ]
  end

  defp stats_panel(state) do
    uptime_seconds = System.monotonic_time(:second) - state.boot_time

    last_event =
      case state.last_event_at do
        nil -> "—"
        %DateTime{} = dt -> Calendar.strftime(dt, "%H:%M:%S UTC")
      end

    text =
      """

        Node:              #{node()}
        BEAM uptime:       #{format_seconds(uptime_seconds)}

        Total messages:    #{state.stats.messages}
        Unique users:      #{state.stats.unique_users}

        Last activity:     #{last_event}

        Live LiveView URL: http://localhost:4000/
      """

    %Paragraph{
      text: text,
      style: %Style{fg: :white},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: border_style(state.focus, :stats),
        title: panel_title("Stats", state.focus, :stats)
      }
    }
  end

  defp recent_messages_panel(state) do
    items =
      case state.messages do
        [] ->
          [
            %Line{
              spans: [
                %Span{content: "(no messages yet)", style: %Style{fg: :dark_gray}}
              ]
            }
          ]

        messages ->
          messages
          |> Enum.take(10)
          |> Enum.map(&MessageLine.render(&1, max_body: 60))
      end

    %WList{
      items: items,
      style: %Style{fg: :white},
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: border_style(state.focus, :recent),
        title: panel_title("Recent", state.focus, :recent)
      }
    }
  end

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

  defp render_footer(state) do
    hint =
      case state.tab do
        0 -> " Tab/Shift+Tab: focus panel   1/2: switch tabs   q: quit"
        _ -> " Tab/1/2: switch tabs   q: quit"
      end

    %Paragraph{
      text: hint,
      style: %Style{fg: :dark_gray},
      block: %Block{
        borders: [:top],
        border_style: %Style{fg: :dark_gray}
      }
    }
  end

  defp border_style(focus, id) do
    if Focus.focused?(focus, id),
      do: %Style{fg: :cyan, modifiers: [:bold]},
      else: %Style{fg: :dark_gray}
  end

  defp panel_title(base, focus, id) do
    if Focus.focused?(focus, id), do: "#{base} ●", else: base
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
