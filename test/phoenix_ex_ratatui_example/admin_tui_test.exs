defmodule PhoenixExRatatuiExample.AdminTuiTest do
  @moduledoc """
  Tests for the SSH-served admin TUI.

  Some tests drive `mount/1` and `render/2` directly with manufactured
  state — those run async and don't touch ExRatatui's NIF-backed
  terminal at all. The "live render" describe block boots the real
  `ExRatatui.Server` against a headless test backend so we know the
  end-to-end render path is wired up correctly.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Frame
  alias PhoenixExRatatuiExample.AdminTui
  alias PhoenixExRatatuiExample.Chat

  setup do
    Chat.reset()
    :ok
  end

  describe "mount/1" do
    test "subscribes to the chat topic and seeds the message list" do
      {:ok, _} = Chat.post_message("alice", "hello")
      {:ok, _} = Chat.post_message("bob", "world")

      {:ok, state} = AdminTui.mount([])

      assert state.tab == 0
      assert length(state.messages) == 2
      assert %{messages: 2, unique_users: 2} = state.stats
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

  describe "render/2" do
    test "produces three widgets (tabs, body, footer) sized to the frame" do
      {:ok, state} = AdminTui.mount([])

      widgets = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert length(widgets) == 3
      assert Enum.all?(widgets, fn {_w, rect} -> is_struct(rect, ExRatatui.Layout.Rect) end)

      total_height =
        widgets
        |> Enum.map(fn {_w, rect} -> rect.height end)
        |> Enum.sum()

      assert total_height == 24
    end

    test "overview tab shows node name and stats with no messages" do
      {:ok, state} = AdminTui.mount([])

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.Paragraph{text: text} = body
      assert text =~ "Node:"
      assert text =~ "(no messages yet)"
      assert text =~ "Total messages:    0"
    end

    test "overview tab shows last activity and last message when present" do
      {:ok, _} = Chat.post_message("alice", "the answer is 42")
      {:ok, state} = AdminTui.mount([])
      state = %{state | last_event_at: DateTime.utc_now()}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.Paragraph{text: text} = body
      assert text =~ "alice: the answer is 42"
      assert text =~ "UTC"
    end

    test "renders messages tab when state.tab == 1" do
      {:ok, _} = Chat.post_message("alice", "the answer is 42")
      {:ok, state} = AdminTui.mount([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.List{items: items} = body
      assert Enum.any?(items, &String.contains?(&1, "alice"))
      assert Enum.any?(items, &String.contains?(&1, "the answer is 42"))
    end

    test "messages tab shows placeholder when empty" do
      {:ok, state} = AdminTui.mount([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.List{items: [item]} = body
      assert item =~ "no messages yet"
    end

    test "messages tab truncates long message bodies" do
      long_body = String.duplicate("x", 100)
      {:ok, _} = Chat.post_message("alice", long_body)
      {:ok, state} = AdminTui.mount([])
      state = %{state | tab: 1}

      [_tabs, {body, _}, _footer] = AdminTui.render(state, %Frame{width: 80, height: 24})

      assert %ExRatatui.Widgets.List{items: [item]} = body
      assert String.ends_with?(item, "…")
    end
  end

  describe "handle_event/2" do
    test "q quits" do
      assert {:stop, %{}} =
               AdminTui.handle_event(
                 %ExRatatui.Event.Key{code: "q", kind: "press"},
                 %{tab: 0}
               )
    end

    test "tab cycles tab index" do
      {:noreply, state} =
        AdminTui.handle_event(
          %ExRatatui.Event.Key{code: "tab", kind: "press"},
          %{tab: 0}
        )

      assert state.tab == 1

      {:noreply, state} =
        AdminTui.handle_event(
          %ExRatatui.Event.Key{code: "tab", kind: "press"},
          state
        )

      assert state.tab == 0
    end

    test "1 / h / left switch to overview, 2 / l / right switch to messages" do
      for code <- ["1", "h", "left"] do
        {:noreply, state} =
          AdminTui.handle_event(
            %ExRatatui.Event.Key{code: code, kind: "press"},
            %{tab: 1}
          )

        assert state.tab == 0, "expected #{code} to switch to tab 0"
      end

      for code <- ["2", "l", "right"] do
        {:noreply, state} =
          AdminTui.handle_event(
            %ExRatatui.Event.Key{code: code, kind: "press"},
            %{tab: 0}
          )

        assert state.tab == 1, "expected #{code} to switch to tab 1"
      end
    end

    test "unknown events are ignored" do
      state = %{tab: 0}

      assert {:noreply, ^state} =
               AdminTui.handle_event(
                 %ExRatatui.Event.Key{code: "z", kind: "press"},
                 state
               )
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
        # Force a render and wait for the server to be done with it.
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
end
