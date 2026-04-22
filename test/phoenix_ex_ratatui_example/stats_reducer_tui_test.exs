defmodule PhoenixExRatatuiExample.StatsReducerTuiTest do
  @moduledoc """
  Tests for the reducer-runtime stats dashboard TUI.

  Mirrors `AdminTuiTest` — unit tests for `init/1`, `render/2`, `update/2`
  that avoid the NIF, plus a live-render describe that boots the real
  `ExRatatui.Server` against a headless test backend.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias ExRatatui.Frame
  alias ExRatatui.Text.Line

  alias ExRatatui.Widgets.{
    BarChart,
    Calendar,
    Chart,
    Paragraph,
    Sparkline
  }

  alias PhoenixExRatatuiExample.Chat
  alias PhoenixExRatatuiExample.StatsReducerTui

  setup do
    Chat.reset()
    :ok
  end

  describe "init/1" do
    test "subscribes to the chat topic, seeds messages, and primes history buffers" do
      {:ok, _} = Chat.post_message("alice", "hello")
      {:ok, _} = Chat.post_message("bob", "world")

      {:ok, state} = StatsReducerTui.init([])

      assert state.tab == 0
      assert length(state.messages) == 2
      assert %{messages: 2, unique_users: 2} = state.stats
      assert state.per_user == [{"alice", 1}, {"bob", 1}]
      assert state.per_day |> Map.values() |> Enum.sum() == 2
      assert state.prev_total == 2
      assert length(state.history.total_msgs) == 60
      assert length(state.history.rate) == 60
      assert Enum.all?(state.history.rate, &(&1 == 0))

      # Subscribed in init → next post should come straight to us.
      {:ok, message} = Chat.post_message("carol", "ping")
      assert_receive {:new_message, ^message}
    end

    test "starts at tab 0 with an empty room" do
      {:ok, state} = StatsReducerTui.init([])
      assert state.tab == 0
      assert state.messages == []
      assert state.notification == nil
      assert state.per_user == []
      assert state.per_day == %{}
      assert %{messages: 0, unique_users: 0} = state.stats
    end
  end

  describe "render/2 — dashboard tab" do
    test "produces tabs + overview header + sparkline + bar chart + totals chart + footer" do
      {:ok, state} = StatsReducerTui.init([])

      widgets = StatsReducerTui.render(state, %Frame{width: 120, height: 40})

      assert length(widgets) == 6

      kinds = Enum.map(widgets, fn {w, _rect} -> w.__struct__ end)

      assert Enum.member?(kinds, Paragraph)
      assert Enum.member?(kinds, Sparkline)
      assert Enum.member?(kinds, BarChart)
      assert Enum.member?(kinds, Chart)
    end

    test "overview header mentions node, totals, and last message" do
      {:ok, _} = Chat.post_message("alice", "hi there")
      {:ok, state} = StatsReducerTui.init([])

      widgets = StatsReducerTui.render(state, %Frame{width: 120, height: 40})

      header =
        Enum.find_value(widgets, fn
          {%Paragraph{block: %{title: "Overview"}} = p, _} -> p
          _ -> nil
        end)

      assert header
      assert header.text =~ "Node:"
      assert header.text =~ "Messages: 1"
      assert header.text =~ "alice: hi there"
    end

    test "bar chart reflects top posters" do
      {:ok, _} = Chat.post_message("alice", "1")
      {:ok, _} = Chat.post_message("alice", "2")
      {:ok, _} = Chat.post_message("bob", "3")

      {:ok, state} = StatsReducerTui.init([])

      widgets = StatsReducerTui.render(state, %Frame{width: 120, height: 40})

      bar_chart =
        Enum.find_value(widgets, fn
          {%BarChart{} = b, _} -> b
          _ -> nil
        end)

      labels = Enum.map(bar_chart.data, & &1.label)
      values = Enum.map(bar_chart.data, & &1.value)

      assert labels == ["alice", "bob"]
      assert values == [2, 1]
    end
  end

  describe "render/2 — messages tab" do
    test "renders rich-text message lines" do
      {:ok, _} = Chat.post_message("alice", "the answer is 42")
      {:ok, state} = StatsReducerTui.init([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] =
        StatsReducerTui.render(state, %Frame{width: 120, height: 40})

      assert %ExRatatui.Widgets.List{items: [%Line{spans: spans}]} = body
      text = Enum.map_join(spans, "", & &1.content)
      assert text =~ "alice"
      assert text =~ "the answer is 42"
    end

    test "empty state renders a placeholder Line" do
      {:ok, state} = StatsReducerTui.init([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] =
        StatsReducerTui.render(state, %Frame{width: 120, height: 40})

      assert %ExRatatui.Widgets.List{items: [%Line{spans: [span]}]} = body
      assert span.content =~ "no messages yet"
    end
  end

  describe "render/2 — calendar tab" do
    test "renders a Calendar widget for today's month with events derived from per_day" do
      {:ok, _} = Chat.post_message("alice", "hi")
      {:ok, state} = StatsReducerTui.init([])
      state = %{state | tab: 2}

      [_tabs, {body, _}, _footer] =
        StatsReducerTui.render(state, %Frame{width: 120, height: 40})

      assert %Calendar{display_date: %Date{}} = body
      assert is_map(body.events)
      assert map_size(body.events) >= 1
    end

    test "events are bucketed by count: 1 is light, 2–5 is bold green, 6+ inverts colors" do
      {:ok, state} = StatsReducerTui.init([])

      d_low = ~D[2026-04-01]
      d_mid = ~D[2026-04-02]
      d_high = ~D[2026-04-03]

      state = %{state | tab: 2, per_day: %{d_low => 1, d_mid => 3, d_high => 10}}

      [_tabs, {body, _}, _footer] =
        StatsReducerTui.render(state, %Frame{width: 120, height: 40})

      assert body.events[d_low].fg == :light_green
      assert body.events[d_mid].fg == :green
      assert :bold in body.events[d_mid].modifiers
      # 6+ uses a background fill to make the day pop.
      assert body.events[d_high].bg == :green
    end
  end

  describe "render/2 — footer" do
    test "footer shows notification when present" do
      {:ok, state} = StatsReducerTui.init([])
      state = %{state | notification: "New message from alice"}

      widgets = StatsReducerTui.render(state, %Frame{width: 120, height: 40})

      {footer, _} = List.last(widgets)
      assert %Paragraph{text: text} = footer
      assert text =~ "New message from alice"
    end
  end

  describe "update/2 — events" do
    test "q quits" do
      {:ok, state} = StatsReducerTui.init([])
      assert {:stop, ^state} = StatsReducerTui.update({:event, key("q")}, state)
    end

    test "number keys jump directly to tabs" do
      {:ok, state} = StatsReducerTui.init([])

      {:noreply, state} = StatsReducerTui.update({:event, key("3")}, state)
      assert state.tab == 2

      {:noreply, state} = StatsReducerTui.update({:event, key("1")}, state)
      assert state.tab == 0
    end

    test "l / right step forward, h / left step back, tab cycles" do
      {:ok, state} = StatsReducerTui.init([])

      # forward through all 3 tabs
      {:noreply, state} = StatsReducerTui.update({:event, key("l")}, state)
      assert state.tab == 1
      {:noreply, state} = StatsReducerTui.update({:event, key("right")}, state)
      assert state.tab == 2
      # clamp at last tab
      {:noreply, same} = StatsReducerTui.update({:event, key("right")}, state)
      assert same.tab == 2

      # backward
      {:noreply, state} = StatsReducerTui.update({:event, key("h")}, same)
      assert state.tab == 1
      {:noreply, state} = StatsReducerTui.update({:event, key("left")}, state)
      assert state.tab == 0
      # clamp at first tab
      {:noreply, same} = StatsReducerTui.update({:event, key("left")}, state)
      assert same.tab == 0

      # tab cycles 0 → 1 → 2 → 0
      {:noreply, state} = StatsReducerTui.update({:event, key("tab")}, same)
      assert state.tab == 1
      {:noreply, state} = StatsReducerTui.update({:event, key("tab")}, state)
      assert state.tab == 2
      {:noreply, state} = StatsReducerTui.update({:event, key("tab")}, state)
      assert state.tab == 0
    end

    test "unknown events are ignored" do
      {:ok, state} = StatsReducerTui.init([])
      assert {:noreply, ^state} = StatsReducerTui.update({:event, key("z")}, state)
    end

    test "unknown info messages are swallowed by the catch-all clause" do
      {:ok, state} = StatsReducerTui.init([])
      assert {:noreply, ^state} = StatsReducerTui.update({:info, :some_unexpected_message}, state)
      assert {:noreply, ^state} = StatsReducerTui.update(:totally_bogus, state)
    end
  end

  describe "update/2 — info messages" do
    test "{:new_message, msg} prepends to messages and shows notification with a batch command" do
      {:ok, state} = StatsReducerTui.init([])
      {:ok, message} = Chat.post_message("alice", "hi")

      {:noreply, next, opts} =
        StatsReducerTui.update({:info, {:new_message, message}}, state)

      assert [^message | _] = next.messages
      assert %DateTime{} = next.last_event_at
      assert next.notification =~ "alice"
      assert [%ExRatatui.Command{kind: :batch}] = opts[:commands]
    end

    test ":refresh_stats returns async command and skips render" do
      {:ok, state} = StatsReducerTui.init([])

      {:noreply, ^state, opts} =
        StatsReducerTui.update({:info, :refresh_stats}, state)

      assert opts[:render?] == false
      assert [%ExRatatui.Command{kind: :async}] = opts[:commands]
    end

    test "{:stats_refreshed, {stats, per_user, per_day}} updates state and shifts the history window" do
      {:ok, state} = StatsReducerTui.init([])
      original_first = hd(state.history.total_msgs)

      new_stats = %{messages: 5, unique_users: 3}
      per_user = [{"alice", 3}, {"bob", 2}]
      per_day = %{Date.utc_today() => 5}

      {:noreply, next} =
        StatsReducerTui.update(
          {:info, {:stats_refreshed, {new_stats, per_user, per_day}}},
          state
        )

      assert next.stats == new_stats
      assert next.per_user == per_user
      assert next.per_day == per_day
      assert next.prev_total == 5
      assert List.last(next.history.total_msgs) == 5
      assert List.last(next.history.rate) == 5
      # The window length stays constant and the oldest sample is
      # dropped from the front.
      assert length(next.history.total_msgs) == 60
      refute hd(next.history.total_msgs) == original_first and original_first == 5
    end

    test ":clear_notification clears the notification" do
      {:ok, state} = StatsReducerTui.init([])
      state = %{state | notification: "something"}

      {:noreply, next} =
        StatsReducerTui.update({:info, :clear_notification}, state)

      assert next.notification == nil
    end
  end

  describe "subscriptions/1" do
    test "declares a 1-second stats refresh interval" do
      {:ok, state} = StatsReducerTui.init([])
      subs = StatsReducerTui.subscriptions(state)

      assert [%ExRatatui.Subscription{id: :stats_refresh, kind: :interval, interval_ms: 1_000}] =
               subs
    end
  end

  describe "format_seconds/1" do
    test "formats seconds under a minute" do
      assert StatsReducerTui.format_seconds(0) == "0s"
      assert StatsReducerTui.format_seconds(42) == "42s"
    end

    test "formats seconds as minutes and seconds" do
      assert StatsReducerTui.format_seconds(60) == "1m 0s"
      assert StatsReducerTui.format_seconds(125) == "2m 5s"
    end

    test "formats seconds as hours and minutes" do
      assert StatsReducerTui.format_seconds(3600) == "1h 0m"
      assert StatsReducerTui.format_seconds(7260) == "2h 1m"
    end
  end

  describe "live render via ExRatatui.Server" do
    test "boots through the Server, renders, and quits cleanly" do
      {:ok, _} = Chat.post_message("alice", "hello-from-test")

      {:ok, pid} =
        ExRatatui.Server.start_link(
          mod: StatsReducerTui,
          name: nil,
          test_mode: {120, 40}
        )

      try do
        _ = :sys.get_state(pid)
        %{terminal_ref: terminal_ref} = :sys.get_state(pid)

        content = ExRatatui.get_buffer_content(terminal_ref)

        assert content =~ "Stats TUI (Reducer)"
        assert content =~ "Dashboard"

        snapshot = ExRatatui.Runtime.snapshot(pid)
        assert snapshot.mode == :reducer
        assert snapshot.render_count >= 1
        assert snapshot.subscription_count == 1
      after
        ref = Process.monitor(pid)
        GenServer.stop(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      end
    end
  end

  # -- Helpers --

  defp key(code), do: %Event.Key{code: code, kind: "press"}
end
