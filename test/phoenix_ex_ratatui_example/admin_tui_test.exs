defmodule PhoenixExRatatuiExample.AdminTuiTest do
  @moduledoc """
  Tests for the admin TUI.

  Unit tests drive `init/1`, `render/2`, and `update/2` with
  manufactured state — no NIF, no real terminal. The "live render"
  describe boots the real `ExRatatui.Server` against a headless test
  backend so the end-to-end render path is covered.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias ExRatatui.Frame
  alias ExRatatui.Text.Line

  alias ExRatatui.Widgets.{
    BarChart,
    Chart,
    Paragraph,
    Sparkline
  }

  alias PhoenixExRatatuiExample.AdminTui
  alias PhoenixExRatatuiExample.Chat

  setup do
    Chat.reset()
    :ok
  end

  describe "init/1" do
    test "subscribes to the chat topic, seeds messages, and primes history buffers" do
      {:ok, _} = Chat.post_message("alice", "hello")
      {:ok, _} = Chat.post_message("bob", "world")

      {:ok, state} = AdminTui.init([])

      assert state.tab == 0
      assert length(state.messages) == 2
      assert %{messages: 2, unique_users: 2} = state.stats
      assert state.per_user == [{"alice", 1}, {"bob", 1}]
      assert state.prev_total == 2
      assert length(state.history.total_msgs) == 60
      assert Enum.all?(state.history.rate, &(&1 == 0))

      # Subscribed in init → next post should come straight to us.
      {:ok, message} = Chat.post_message("carol", "ping")
      assert_receive {:new_message, ^message}
    end

    test "starts at tab 0 with an empty room" do
      {:ok, state} = AdminTui.init([])
      assert state.tab == 0
      assert state.messages == []
      assert state.notification == nil
      assert state.per_user == []
      assert %{messages: 0, unique_users: 0} = state.stats
    end
  end

  describe "render/2 — dashboard tab" do
    test "produces tabs + overview header + sparkline + bar chart + totals chart + footer" do
      {:ok, state} = AdminTui.init([])

      widgets = AdminTui.render(state, %Frame{width: 120, height: 40})

      assert length(widgets) == 6

      kinds = Enum.map(widgets, fn {w, _rect} -> w.__struct__ end)
      assert Paragraph in kinds
      assert Sparkline in kinds
      assert BarChart in kinds
      assert Chart in kinds
    end

    test "overview header shows rich-text node and totals" do
      {:ok, _} = Chat.post_message("alice", "hi there")
      {:ok, state} = AdminTui.init([])

      widgets = AdminTui.render(state, %Frame{width: 120, height: 40})

      header =
        Enum.find_value(widgets, fn
          {%Paragraph{text: [%Line{} | _]} = p, _} -> p
          _ -> nil
        end)

      assert header
      # text is a [%Line{}], so flatten spans for content assertions.
      flat =
        header.text
        |> Enum.flat_map(& &1.spans)
        |> Enum.map_join("", & &1.content)

      assert flat =~ "Node:"
      assert flat =~ "Uptime:"
      # stats.messages is 1 after one post.
      assert flat =~ "Messages:"
      assert flat =~ "1"
      assert flat =~ "alice: hi there"
    end

    test "bar chart reflects top posters" do
      {:ok, _} = Chat.post_message("alice", "1")
      {:ok, _} = Chat.post_message("alice", "2")
      {:ok, _} = Chat.post_message("bob", "3")

      {:ok, state} = AdminTui.init([])

      widgets = AdminTui.render(state, %Frame{width: 120, height: 40})

      bar_chart =
        Enum.find_value(widgets, fn
          {%BarChart{} = b, _} -> b
          _ -> nil
        end)

      assert Enum.map(bar_chart.data, & &1.label) == ["alice", "bob"]
      assert Enum.map(bar_chart.data, & &1.value) == [2, 1]
    end
  end

  describe "render/2 — messages tab" do
    test "renders rich-text message lines" do
      {:ok, _} = Chat.post_message("alice", "the answer is 42")
      {:ok, state} = AdminTui.init([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 120, height: 40})

      assert %ExRatatui.Widgets.List{items: [%Line{spans: spans}]} = body
      text = Enum.map_join(spans, "", & &1.content)
      assert text =~ "alice"
      assert text =~ "the answer is 42"
    end

    test "empty state renders a placeholder Line" do
      {:ok, state} = AdminTui.init([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 120, height: 40})

      assert %ExRatatui.Widgets.List{items: [%Line{spans: [span]}]} = body
      assert span.content =~ "no messages yet"
    end
  end

  describe "render/2 — footer" do
    test "footer shows actions" do
      {:ok, state} = AdminTui.init([])

      widgets = AdminTui.render(state, %Frame{width: 120, height: 40})

      {footer, _} = List.last(widgets)
      assert %Paragraph{text: %Line{spans: spans}} = footer
      text = Enum.map_join(spans, "", & &1.content)
      assert text =~ " Tab  cycle  q  quit"
    end
  end

  describe "update/2 — events" do
    test "q quits" do
      {:ok, state} = AdminTui.init([])
      assert {:stop, ^state} = AdminTui.update({:event, key("q")}, state)
    end

    test "tab cycles" do
      {:ok, state} = AdminTui.init([])

      # tab cycles 0 → 1 → 0
      {:noreply, state} = AdminTui.update({:event, key("tab")}, state)
      assert state.tab == 1
      {:noreply, state} = AdminTui.update({:event, key("tab")}, state)
      assert state.tab == 0
    end

    test "unknown events are ignored" do
      {:ok, state} = AdminTui.init([])
      assert {:noreply, ^state} = AdminTui.update({:event, key("z")}, state)
    end

    test "unknown info messages are swallowed by the catch-all clause" do
      {:ok, state} = AdminTui.init([])
      assert {:noreply, ^state} = AdminTui.update({:info, :some_unexpected_message}, state)
      assert {:noreply, ^state} = AdminTui.update(:totally_bogus, state)
    end
  end

  describe "update/2 — info messages" do
    test "{:new_message, msg} prepends to messages and shows a notification with a batch command" do
      {:ok, state} = AdminTui.init([])
      {:ok, message} = Chat.post_message("alice", "hi")

      {:noreply, next, opts} = AdminTui.update({:info, {:new_message, message}}, state)

      assert [^message | _] = next.messages
      assert %DateTime{} = next.last_event_at
      assert next.notification =~ "alice"
      assert [%ExRatatui.Command{kind: :batch}] = opts[:commands]
    end

    test ":refresh_stats returns an async command and skips render" do
      {:ok, state} = AdminTui.init([])

      {:noreply, ^state, opts} = AdminTui.update({:info, :refresh_stats}, state)

      assert opts[:render?] == false
      assert [%ExRatatui.Command{kind: :async}] = opts[:commands]
    end

    test "{:stats_refreshed, {stats, per_user}} updates state and shifts the history window" do
      {:ok, state} = AdminTui.init([])

      new_stats = %{messages: 5, unique_users: 3}
      per_user = [{"alice", 3}, {"bob", 2}]

      {:noreply, next} =
        AdminTui.update({:info, {:stats_refreshed, {new_stats, per_user}}}, state)

      assert next.stats == new_stats
      assert next.per_user == per_user
      assert next.prev_total == 5
      assert List.last(next.history.total_msgs) == 5
      assert List.last(next.history.rate) == 5
      assert length(next.history.total_msgs) == 60
    end

    test ":clear_notification clears the notification" do
      {:ok, state} = AdminTui.init([])
      state = %{state | notification: "something"}

      {:noreply, next} = AdminTui.update({:info, :clear_notification}, state)
      assert next.notification == nil
    end
  end

  describe "subscriptions/1" do
    test "declares a 1-second stats refresh interval" do
      {:ok, state} = AdminTui.init([])
      subs = AdminTui.subscriptions(state)

      assert [%ExRatatui.Subscription{id: :stats_refresh, kind: :interval, interval_ms: 1_000}] =
               subs
    end
  end

  describe "format_seconds/1" do
    test "formats seconds under a minute" do
      assert AdminTui.format_seconds(0) == "0s"
      assert AdminTui.format_seconds(42) == "42s"
      assert AdminTui.format_seconds(59) == "59s"
    end

    test "formats seconds as minutes and seconds" do
      assert AdminTui.format_seconds(60) == "1m 0s"
      assert AdminTui.format_seconds(125) == "2m 5s"
      assert AdminTui.format_seconds(3599) == "59m 59s"
    end

    test "formats seconds as hours and minutes" do
      assert AdminTui.format_seconds(3600) == "1h 0m"
      assert AdminTui.format_seconds(7260) == "2h 1m"
    end
  end

  describe "live render via ExRatatui.Server" do
    test "boots through the Server, renders, and quits cleanly" do
      {:ok, _} = Chat.post_message("alice", "hello-from-test")

      {:ok, pid} =
        ExRatatui.Server.start_link(
          mod: AdminTui,
          name: nil,
          test_mode: {140, 40}
        )

      try do
        _ = :sys.get_state(pid)
        %{terminal_ref: terminal_ref} = :sys.get_state(pid)

        content = ExRatatui.get_buffer_content(terminal_ref)

        assert content =~ "Phoenix"
        assert content =~ "ExRatatui"
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
