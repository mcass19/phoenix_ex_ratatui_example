defmodule PhoenixExRatatuiExample.Chat do
  @moduledoc """
  Tiny in-memory chat room used to drive the demo.

  The point of this module is **not** to be a great chat
  implementation — it just needs to generate enough state for the
  admin TUI to have something interesting to display.

  Messages are kept in a `GenServer` (capped at the most recent 200)
  and every send broadcasts on a Phoenix.PubSub topic. Both the
  LiveView in the browser and `PhoenixExRatatuiExample.AdminTui`
  subscribe to the same topic, so anything posted on the web shows
  up live in any TUI session reached over SSH.
  """

  use GenServer

  alias Phoenix.PubSub

  @pubsub PhoenixExRatatuiExample.PubSub
  @topic "chat:room"
  @max_messages 200

  defmodule Message do
    @moduledoc false
    defstruct [:id, :user, :body, :inserted_at]

    @type t :: %__MODULE__{
            id: pos_integer(),
            user: String.t(),
            body: String.t(),
            inserted_at: DateTime.t()
          }
  end

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current message list (newest last)."
  @spec list_messages() :: [Message.t()]
  def list_messages, do: GenServer.call(__MODULE__, :list_messages)

  @doc "Returns chat statistics for the admin dashboard."
  @spec stats() :: %{messages: non_neg_integer(), unique_users: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "Posts a new message and broadcasts it on the chat topic."
  @spec post_message(String.t(), String.t()) :: {:ok, Message.t()} | {:error, term()}
  def post_message(user, body) do
    GenServer.call(__MODULE__, {:post_message, user, body})
  end

  @doc """
  Wipes all messages and resets the id counter. Test-only helper —
  there's no UI for it. Used by the test setup so the application's
  long-lived Chat process starts each test on a clean slate.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Subscribe the calling process to chat events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  @doc "Broadcast that a presence count has changed (called from the LiveView)."
  @spec broadcast_presence(non_neg_integer()) :: :ok
  def broadcast_presence(count) do
    PubSub.broadcast(@pubsub, @topic, {:presence, count})
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{messages: [], next_id: 1}}
  end

  @impl true
  def handle_call(:list_messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{messages: [], next_id: 1}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    unique = state.messages |> Enum.map(& &1.user) |> Enum.uniq() |> length()
    {:reply, %{messages: length(state.messages), unique_users: unique}, state}
  end

  @impl true
  def handle_call({:post_message, user, body}, _from, state) do
    user = String.trim(user || "")
    body = String.trim(body || "")

    cond do
      user == "" ->
        {:reply, {:error, :empty_user}, state}

      body == "" ->
        {:reply, {:error, :empty_body}, state}

      true ->
        message = %Message{
          id: state.next_id,
          user: user,
          body: body,
          inserted_at: DateTime.utc_now()
        }

        new_messages =
          [message | state.messages]
          |> Enum.take(@max_messages)

        PubSub.broadcast(@pubsub, @topic, {:new_message, message})

        {:reply, {:ok, message}, %{state | messages: new_messages, next_id: state.next_id + 1}}
    end
  end
end
