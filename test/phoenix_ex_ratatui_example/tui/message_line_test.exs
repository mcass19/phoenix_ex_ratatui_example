defmodule PhoenixExRatatuiExample.Tui.MessageLineTest do
  @moduledoc """
  Unit tests for the shared rich-text message renderer used by both
  TUIs. No NIF involvement — these only exercise struct construction
  and the hash-based color lookup.
  """

  use ExUnit.Case, async: true

  alias ExRatatui.Text.Line
  alias PhoenixExRatatuiExample.Chat.Message
  alias PhoenixExRatatuiExample.Tui.MessageLine

  describe "user_color/1" do
    test "returns the same color for the same username" do
      assert MessageLine.user_color("alice") == MessageLine.user_color("alice")
    end

    test "returns a known palette atom" do
      for user <- ["alice", "bob", "carol", "dave", "eve"] do
        color = MessageLine.user_color(user)

        assert color in ~w(cyan green yellow magenta blue red light_cyan light_green light_magenta)a,
               "unexpected color #{inspect(color)} for #{user}"
      end
    end
  end

  describe "render/2" do
    setup do
      %{
        message: %Message{
          id: 1,
          user: "alice",
          body: "hello",
          inserted_at: ~U[2026-04-22 13:45:07Z]
        }
      }
    end

    test "produces a %Line{} with timestamp, user, separator, and body spans", %{message: msg} do
      assert %Line{spans: [ts, user, sep, body]} = MessageLine.render(msg)

      assert ts.content == "[13:45:07] "
      assert ts.style.fg == :dark_gray

      assert user.content == "alice"
      assert user.style.fg == MessageLine.user_color("alice")
      assert :bold in user.style.modifiers

      assert sep.content == ": "
      assert body.content == "hello"
      assert body.style.fg == :white
    end

    test "leaves short bodies untouched (no ellipsis)", %{message: msg} do
      %Line{spans: spans} = MessageLine.render(msg, max_body: 80)
      [_, _, _, body] = spans
      refute String.ends_with?(body.content, "…")
    end

    test "truncates long bodies with an ellipsis", %{message: %Message{} = msg} do
      long = %{msg | body: String.duplicate("x", 100)}
      %Line{spans: [_, _, _, body]} = MessageLine.render(long, max_body: 20)
      assert String.length(body.content) == 20
      assert String.ends_with?(body.content, "…")
    end
  end
end
