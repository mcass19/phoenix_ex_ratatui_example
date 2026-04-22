defmodule PhoenixExRatatuiExample.AdminTuiTest do
  @moduledoc """
  Tests for the SSH-served admin TUI.

  Most tests drive `mount/1` and `render/2` directly with manufactured
  state — those run without touching ExRatatui's NIF-backed terminal.
  The "live render" describe boots the real `ExRatatui.Server` against
  a headless test backend so the end-to-end render path is covered.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias ExRatatui.Focus
  alias ExRatatui.Frame
  alias ExRatatui.Text.Line
  alias PhoenixExRatatuiExample.AdminTui
  alias PhoenixExRatatuiExample.Chat

  setup do
    Chat.reset()
    :ok
  end

  describe "mount/1" do
    test "subscribes to the chat topic, seeds messages, and sets up focus" do
      {:ok, _} = Chat.post_message("alice", "hello")
      {:ok, _} = Chat.post_message("bob", "world")

      {:ok, state} = AdminTui.mount([])

      assert state.tab == 0
      assert length(state.messages) == 2
      assert %{messages: 2, unique_users: 2} = state.stats
      assert %Focus{} = state.focus
      assert Focus.current(state.focus) == :stats

      # Subscribed in mount → next post should come straight to us.
      {:ok, message} = Chat.post_message("carol", "ping")
      assert_receive {:new_message, ^message}
    end

    test "starts at tab 0 with an empty room" do
      {:ok, state} = AdminTui.mount([])
      assert state.tab == 0
      assert state.messages == []
      assert %{messages: 0, unique_users: 0} = state.stats
    end
  end

  describe "render/2 — overview tab" do
    test "produces tabs + two focused panels + footer, all sized to the frame" do
      {:ok, state} = AdminTui.mount([])

      widgets = AdminTui.render(state, %Frame{width: 80, height: 24})

      # tabs, stats_panel, recent_panel, footer
      assert length(widgets) == 4

      assert Enum.all?(widgets, fn {_w, rect} -> is_struct(rect, ExRatatui.Layout.Rect) end)

      # Body panels should sit side-by-side and their heights should
      # sum with tabs + footer to the full frame height.
      heights =
        widgets
        |> Enum.map(fn {_w, rect} -> rect.height end)

      [tabs_h, left_h, _right_h, footer_h] = heights
      assert tabs_h + left_h + footer_h == 24
    end

    test "stats panel shows node name and stats" do
      {:ok, _} = Chat.post_message("alice", "hello")
      {:ok, state} = AdminTui.mount([])

      [_tabs, {stats_panel, _}, _recent, _footer] =
        AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.Paragraph{text: text, block: block} = stats_panel
      assert text =~ "Node:"
      assert text =~ "Total messages:    1"
      assert block.title =~ "Stats"
    end

    test "recent panel renders messages as rich-text Lines" do
      {:ok, _} = Chat.post_message("alice", "the answer is 42")
      {:ok, state} = AdminTui.mount([])

      [_tabs, _stats, {recent, _}, _footer] =
        AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.List{items: [%Line{spans: spans} | _]} = recent

      text = Enum.map_join(spans, "", & &1.content)
      assert text =~ "alice"
      assert text =~ "the answer is 42"
    end

    test "focused panel border uses cyan; unfocused uses dark_gray" do
      {:ok, state} = AdminTui.mount([])

      [_tabs, {stats, _}, {recent, _}, _footer] =
        AdminTui.render(state, %Frame{width: 80, height: 24})

      assert stats.block.border_style.fg == :cyan
      assert recent.block.border_style.fg == :dark_gray

      # Rotate focus and re-render.
      state = %{state | focus: Focus.next(state.focus)}

      [_tabs, {stats, _}, {recent, _}, _footer] =
        AdminTui.render(state, %Frame{width: 80, height: 24})

      assert stats.block.border_style.fg == :dark_gray
      assert recent.block.border_style.fg == :cyan
    end
  end

  describe "render/2 — messages tab" do
    test "renders rich-text message lines when tab == 1" do
      {:ok, _} = Chat.post_message("alice", "the answer is 42")
      {:ok, state} = AdminTui.mount([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.List{items: [%Line{spans: spans}]} = body
      text = Enum.map_join(spans, "", & &1.content)
      assert text =~ "alice"
      assert text =~ "the answer is 42"
    end

    test "messages tab shows placeholder when empty" do
      {:ok, state} = AdminTui.mount([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.List{items: [%Line{spans: [span]}]} = body
      assert span.content =~ "no messages yet"
    end

    test "long message bodies are truncated with an ellipsis" do
      long_body = String.duplicate("x", 200)
      {:ok, _} = Chat.post_message("alice", long_body)
      {:ok, state} = AdminTui.mount([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.List{items: [%Line{spans: spans}]} = body
      text = Enum.map_join(spans, "", & &1.content)
      assert String.ends_with?(text, "…")
    end
  end

  describe "handle_event/2" do
    test "q quits" do
      {:ok, state} = AdminTui.mount([])
      assert {:stop, ^state} = AdminTui.handle_event(key("q"), state)
    end

    test "on overview tab, Tab rotates focus instead of switching tabs" do
      {:ok, state} = AdminTui.mount([])
      assert Focus.current(state.focus) == :stats

      {:noreply, state} = AdminTui.handle_event(key("tab"), state)
      assert state.tab == 0
      assert Focus.current(state.focus) == :recent

      {:noreply, state} = AdminTui.handle_event(key("tab"), state)
      assert state.tab == 0
      assert Focus.current(state.focus) == :stats
    end

    test "on messages tab, Tab cycles tabs" do
      {:ok, state} = AdminTui.mount([])
      state = %{state | tab: 1}

      {:noreply, state} = AdminTui.handle_event(key("tab"), state)
      assert state.tab == 0
    end

    test "number keys jump directly to tabs" do
      {:ok, state} = AdminTui.mount([])

      {:noreply, state} = AdminTui.handle_event(key("2"), state)
      assert state.tab == 1

      {:noreply, state} = AdminTui.handle_event(key("1"), state)
      assert state.tab == 0
    end

    test "h / left step back one tab, l / right step forward one tab" do
      {:ok, state} = AdminTui.mount([])

      # From tab 0, left/h clamp at 0.
      {:noreply, same} = AdminTui.handle_event(key("h"), state)
      assert same.tab == 0

      # Move forward with l/right.
      {:noreply, state} = AdminTui.handle_event(key("l"), state)
      assert state.tab == 1

      {:noreply, state} = AdminTui.handle_event(key("right"), state)
      assert state.tab == 1

      # Step back with left.
      {:noreply, state} = AdminTui.handle_event(key("left"), state)
      assert state.tab == 0
    end

    test "unknown events are ignored" do
      {:ok, state} = AdminTui.mount([])
      assert {:noreply, ^state} = AdminTui.handle_event(key("z"), state)
    end
  end

  describe "handle_info/2" do
    test "{:new_message, msg} prepends to messages and updates stats" do
      {:ok, state} = AdminTui.mount([])
      {:ok, message} = Chat.post_message("alice", "hi")

      {:noreply, state} = AdminTui.handle_info({:new_message, message}, state)

      assert [^message | _] = state.messages
      assert state.stats.messages == 1
      assert %DateTime{} = state.last_event_at
    end

    test "ignores presence events" do
      {:ok, state} = AdminTui.mount([])
      assert {:noreply, ^state} = AdminTui.handle_info({:presence, 5}, state)
    end

    test "ignores unknown messages" do
      {:ok, state} = AdminTui.mount([])
      assert {:noreply, ^state} = AdminTui.handle_info(:something_else, state)
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
          test_mode: {120, 30}
        )

      try do
        _ = :sys.get_state(pid)
        %{terminal_ref: terminal_ref} = :sys.get_state(pid)

        content = ExRatatui.get_buffer_content(terminal_ref)

        assert content =~ "Phoenix + ExRatatui"
        assert content =~ "Overview"
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
