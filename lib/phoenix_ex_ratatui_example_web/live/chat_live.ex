defmodule PhoenixExRatatuiExampleWeb.ChatLive do
  @moduledoc """
  Public chat room used to drive the demo.

  Anyone visiting `/` can pick a username, post messages, and watch
  what other connected users are saying. Every send is broadcast on
  `PhoenixExRatatuiExample.Chat`'s PubSub topic, which is the same
  topic the SSH-served `PhoenixExRatatuiExample.AdminTui` subscribes
  to. Posting from the browser updates the terminal in real time.
  """

  use PhoenixExRatatuiExampleWeb, :live_view

  alias PhoenixExRatatuiExample.Chat

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Chat.subscribe()
    end

    username = session["username"] || random_username()

    socket =
      socket
      |> assign(:username, username)
      |> assign(:form, to_form(%{"body" => ""}, as: :message))
      |> stream(:messages, Chat.list_messages())

    {:ok, socket}
  end

  defp random_username do
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    "guest-" <> suffix
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-3xl px-4 py-4 space-y-4">
        <.header>
          Phoenix + ExRatatui demo
          <:subtitle>
            Post a message in the browser, watch it appear in the SSH admin TUI in real time.
          </:subtitle>
        </.header>

        <div class="rounded-box bg-base-200 p-4 flex items-center justify-between">
          <span class="text-sm opacity-70">Posting as</span>
          <form id="rename-form" phx-submit="rename" class="flex items-center gap-2">
            <input
              type="text"
              name="username"
              value={@username}
              class="input input-sm input-bordered w-44"
              aria-label="username"
            />
            <button type="submit" class="btn btn-sm btn-outline btn-secondary">Rename</button>
          </form>
        </div>

        <ul
          id="messages"
          phx-update="stream"
          class="rounded-box bg-base-100 border border-base-300 divide-y divide-base-300 max-h-96 overflow-y-auto"
        >
          <li id="messages-empty" class="hidden only:block p-4 text-center text-sm opacity-60">
            No messages yet — be the first to say hi.
          </li>
          <li :for={{dom_id, message} <- @streams.messages} id={dom_id} class="p-3">
            <div class="flex items-center gap-2 text-sm">
              <span class="font-semibold">{message.user}</span>
              <span class="opacity-50 text-xs">
                {Calendar.strftime(message.inserted_at, "%H:%M:%S")}
              </span>
            </div>
            <p class="mt-1">{message.body}</p>
          </li>
        </ul>

        <.form
          for={@form}
          id="message-form"
          phx-submit="send"
        >
          <.input
            field={@form[:body]}
            type="text"
            placeholder="Type a message and hit enter…"
            autocomplete="off"
          />
          <div class="flex justify-end">
            <.button type="submit">Send</.button>
          </div>
        </.form>

        <p class="text-xs opacity-60 text-center">
          Open a terminal and run
          <code class="px-1 rounded bg-base-300">ssh -p 2222 admin@localhost</code>
          (password <code class="px-1 rounded bg-base-300">admin</code>) to see the live admin TUI.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    case Chat.post_message(socket.assigns.username, body) do
      {:ok, _message} ->
        # The {:new_message, _} broadcast we receive in handle_info
        # will push the message into the stream — so we only need to
        # reset the form here.
        {:noreply, assign(socket, :form, to_form(%{"body" => ""}, as: :message))}

      {:error, :empty_body} ->
        {:noreply,
         socket
         |> put_flash(:error, "Message body can't be blank.")
         |> assign(:form, to_form(%{"body" => body}, as: :message))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't send message.")}
    end
  end

  def handle_event("rename", %{"username" => username}, socket) do
    username = username |> to_string() |> String.trim()

    if username == "" do
      {:noreply, put_flash(socket, :error, "Username can't be blank.")}
    else
      {:noreply, assign(socket, :username, username)}
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  def handle_info({:presence, _count}, socket), do: {:noreply, socket}
end
