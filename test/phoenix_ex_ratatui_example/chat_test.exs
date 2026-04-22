defmodule PhoenixExRatatuiExample.ChatTest do
  @moduledoc """
  Exercises the in-memory chat GenServer that backs both the
  LiveView and the SSH admin TUI. We bypass the application-started
  Chat singleton and start a fresh process per test so cases stay
  isolated and can run async.
  """

  use ExUnit.Case, async: false

  alias PhoenixExRatatuiExample.Chat
  alias PhoenixExRatatuiExample.Chat.Message

  setup do
    # The application starts a singleton Chat process — wipe its
    # state between cases instead of trying to restart it (which
    # races the application supervisor).
    Chat.reset()
    :ok
  end

  describe "post_message/2" do
    test "stores a message and returns it" do
      assert {:ok, %Message{user: "alice", body: "hi"}} = Chat.post_message("alice", "hi")
      assert [%Message{user: "alice", body: "hi"}] = Chat.list_messages()
    end

    test "rejects empty body" do
      assert {:error, :empty_body} = Chat.post_message("alice", "")
      assert {:error, :empty_body} = Chat.post_message("alice", "   ")
    end

    test "rejects empty user" do
      assert {:error, :empty_user} = Chat.post_message("", "hello")
    end

    test "broadcasts new messages to subscribers" do
      :ok = Chat.subscribe()
      {:ok, message} = Chat.post_message("bob", "hey")
      assert_receive {:new_message, ^message}
    end

    test "trims whitespace from user and body" do
      assert {:ok, %Message{user: "alice", body: "hi"}} =
               Chat.post_message("  alice  ", "  hi  ")
    end
  end

  describe "list_messages/0" do
    test "returns messages oldest-first (insertion order)" do
      {:ok, _} = Chat.post_message("alice", "first")
      {:ok, _} = Chat.post_message("bob", "second")

      assert [
               %Message{body: "first"},
               %Message{body: "second"}
             ] = Chat.list_messages()
    end
  end

  describe "stats/0" do
    test "counts total messages and unique users" do
      {:ok, _} = Chat.post_message("alice", "1")
      {:ok, _} = Chat.post_message("alice", "2")
      {:ok, _} = Chat.post_message("bob", "3")

      assert %{messages: 3, unique_users: 2} = Chat.stats()
    end

    test "starts at zero" do
      assert %{messages: 0, unique_users: 0} = Chat.stats()
    end
  end

  describe "per_user_counts/0" do
    test "returns counts sorted desc by count, then asc by user" do
      {:ok, _} = Chat.post_message("alice", "1")
      {:ok, _} = Chat.post_message("alice", "2")
      {:ok, _} = Chat.post_message("bob", "3")
      {:ok, _} = Chat.post_message("carol", "4")
      {:ok, _} = Chat.post_message("carol", "5")

      assert [{"alice", 2}, {"carol", 2}, {"bob", 1}] = Chat.per_user_counts()
    end

    test "returns [] for an empty room" do
      assert Chat.per_user_counts() == []
    end
  end

  describe "broadcast_presence/1" do
    test "broadcasts a {:presence, count} message to subscribers" do
      :ok = Chat.subscribe()
      :ok = Chat.broadcast_presence(7)
      assert_receive {:presence, 7}
    end
  end
end
