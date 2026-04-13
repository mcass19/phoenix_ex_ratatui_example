defmodule PhoenixExRatatuiExample.StatsReducerTuiTest do
  @moduledoc """
  Tests for the reducer-runtime stats TUI.

  Mirrors the structure of `AdminTuiTest` — unit tests for `init/1`,
  `render/2`, `update/2` that run async without touching the NIF, plus
  an integration describe that boots the real `ExRatatui.Server` against
  a headless test backend.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Frame
  alias PhoenixExRatatuiExample.Chat
  alias PhoenixExRatatuiExample.StatsReducerTui

  setup do
    Chat.reset()
    :ok
  end

  describe "init/1" do
    test "subscribes to the chat topic and seeds the message list" do
      {:ok, _} = Chat.post_message("alice", "hello")
      {:ok, _} = Chat.post_message("bob", "world")

      {:ok, state} = StatsReducerTui.init([])

      assert state.tab == 0
      assert length(state.messages) == 2
      assert %{messages: 2, unique_users: 2} = state.stats
      # Subscribed in init → next post should come straight to us.
      {:ok, message} = Chat.post_message("carol", "ping")
      assert_receive {:new_message, ^message}
    end

    test "starts at tab 0 with an empty room" do
      {:ok, state} = StatsReducerTui.init([])
      assert state.tab == 0
      assert state.messages == []
      assert state.notification == nil
      assert %{messages: 0, unique_users: 0} = state.stats
    end
  end

  describe "render/2" do
    test "produces three widgets (tabs, body, footer) sized to the frame" do
      {:ok, state} = StatsReducerTui.init([])

      widgets = StatsReducerTui.render(state, %Frame{width: 80, height: 24})

      assert length(widgets) == 3
      assert Enum.all?(widgets, fn {_w, rect} -> is_struct(rect, ExRatatui.Layout.Rect) end)

      total_height =
        widgets
        |> Enum.map(fn {_w, rect} -> rect.height end)
        |> Enum.sum()

      assert total_height == 24
    end

    test "stats tab shows node name and stats with no messages" do
      {:ok, state} = StatsReducerTui.init([])

      [_tabs, {body, _}, _footer] = StatsReducerTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.Paragraph{text: text} = body
      assert text =~ "Node:"
      assert text =~ "(no messages yet)"
      assert text =~ "Total messages:    0"
    end

    test "renders messages tab when state.tab == 1" do
      {:ok, _} = Chat.post_message("alice", "the answer is 42")
      {:ok, state} = StatsReducerTui.init([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = StatsReducerTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.List{items: items} = body
      assert Enum.any?(items, &String.contains?(&1, "alice"))
      assert Enum.any?(items, &String.contains?(&1, "the answer is 42"))
    end

    test "footer shows notification when present" do
      {:ok, state} = StatsReducerTui.init([])
      state = %{state | notification: "New message from alice"}

      [_tabs, _body, {footer, _}] =
        StatsReducerTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.Paragraph{text: text} = footer
      assert text =~ "New message from alice"
    end
  end

  describe "update/2 — events" do
    test "q quits" do
      {:ok, state} = StatsReducerTui.init([])

      assert {:stop, ^state} =
               StatsReducerTui.update({:event, key("q")}, state)
    end

    test "tab cycles tab index" do
      {:ok, state} = StatsReducerTui.init([])

      {:noreply, state} = StatsReducerTui.update({:event, key("tab")}, state)
      assert state.tab == 1

      {:noreply, state} = StatsReducerTui.update({:event, key("tab")}, state)
      assert state.tab == 0
    end

    test "1/h/left switch to stats, 2/l/right switch to messages" do
      {:ok, state} = StatsReducerTui.init([])

      for code <- ["1", "h", "left"] do
        {:noreply, next} =
          StatsReducerTui.update({:event, key(code)}, %{state | tab: 1})

        assert next.tab == 0, "expected #{code} to switch to tab 0"
      end

      for code <- ["2", "l", "right"] do
        {:noreply, next} =
          StatsReducerTui.update({:event, key(code)}, state)

        assert next.tab == 1, "expected #{code} to switch to tab 1"
      end
    end

    test "unknown events are ignored" do
      {:ok, state} = StatsReducerTui.init([])

      assert {:noreply, ^state} =
               StatsReducerTui.update({:event, key("z")}, state)
    end
  end

  describe "update/2 — info messages" do
    test "{:new_message, msg} prepends to messages and shows notification" do
      {:ok, state} = StatsReducerTui.init([])
      {:ok, message} = Chat.post_message("alice", "hi")

      {:noreply, next, opts} =
        StatsReducerTui.update({:info, {:new_message, message}}, state)

      assert [^message | _] = next.messages
      assert %DateTime{} = next.last_event_at
      assert next.notification =~ "alice"
      # Should have a batch command (async stats refresh + send_after dismiss)
      assert [%ExRatatui.Command{kind: :batch}] = opts[:commands]
    end

    test ":refresh_stats returns async command and skips render" do
      {:ok, state} = StatsReducerTui.init([])

      {:noreply, ^state, opts} =
        StatsReducerTui.update({:info, :refresh_stats}, state)

      assert opts[:render?] == false
      assert [%ExRatatui.Command{kind: :async}] = opts[:commands]
    end

    test "{:stats_refreshed, stats} updates stats" do
      {:ok, state} = StatsReducerTui.init([])
      {:ok, _} = Chat.post_message("alice", "hi")
      new_stats = Chat.stats()

      {:noreply, next} =
        StatsReducerTui.update({:info, {:stats_refreshed, new_stats}}, state)

      assert next.stats == new_stats
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
          test_mode: {120, 30}
        )

      try do
        _ = :sys.get_state(pid)
        %{terminal_ref: terminal_ref} = :sys.get_state(pid)

        content = ExRatatui.get_buffer_content(terminal_ref)

        assert content =~ "Stats TUI (Reducer)"
        assert content =~ "Stats"

        # Verify runtime snapshot shows reducer mode
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

  defp key(code), do: %ExRatatui.Event.Key{code: code, kind: "press"}
end
