defmodule PhoenixExRatatuiExampleWeb.ChatLiveTest do
  use PhoenixExRatatuiExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixExRatatuiExample.Chat

  setup do
    Chat.reset()
    :ok
  end

  test "renders the chat heading and SSH hint", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Phoenix + ExRatatui"
    assert html =~ "ssh -p 2222 admin@localhost"
    assert has_element?(view, "#message-form")
  end

  test "submitting a message inserts it into the stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#message-form", message: %{body: "hello there"})
    |> render_submit()

    assert render(view) =~ "hello there"
    assert [%Chat.Message{body: "hello there"}] = Chat.list_messages()
  end

  test "an empty submission shows a flash error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#message-form", message: %{body: ""})
      |> render_submit()

    assert html =~ "Message body can&#39;t be blank."
  end

  test "rename updates the username assign", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#rename-form")
    |> render_submit(%{username: "kieran"})

    view
    |> form("#message-form", message: %{body: "hi"})
    |> render_submit()

    assert [%Chat.Message{user: "kieran", body: "hi"}] = Chat.list_messages()
  end

  test "rename with empty username shows flash error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("#rename-form")
      |> render_submit(%{username: ""})

    assert html =~ "Username can&#39;t be blank."
  end

  test "presence events are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    send(view.pid, {:presence, 42})

    # View still renders fine after receiving the presence event
    assert render(view) =~ "Phoenix + ExRatatui"
  end
end
