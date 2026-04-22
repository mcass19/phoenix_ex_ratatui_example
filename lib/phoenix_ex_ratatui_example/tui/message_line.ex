defmodule PhoenixExRatatuiExample.Tui.MessageLine do
  @moduledoc """
  Shared rich-text renderer used by both TUIs to format a `Chat.Message`
  as a styled `ExRatatui.Text.Line` — timestamp in dim gray, username in
  a color derived from `:erlang.phash2/2` (stable per user), body in white.

  Keeping this in one place means the admin (callback) and stats (reducer)
  TUIs render messages identically, and swapping the color palette is a
  one-line change.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias PhoenixExRatatuiExample.Chat.Message

  # Bright, readable colors that survive on light and dark terminals.
  @user_colors ~w(cyan green yellow magenta blue red light_cyan light_green light_magenta)a

  @doc "Turns a Chat.Message into a %Line{} with per-span styling."
  @spec render(Message.t(), keyword()) :: Line.t()
  def render(%Message{} = message, opts \\ []) do
    max_body = Keyword.get(opts, :max_body, 80)

    %Line{
      spans: [
        %Span{
          content: "[" <> Calendar.strftime(message.inserted_at, "%H:%M:%S") <> "] ",
          style: %Style{fg: :dark_gray}
        },
        %Span{
          content: message.user,
          style: %Style{fg: user_color(message.user), modifiers: [:bold]}
        },
        %Span{content: ": ", style: %Style{fg: :dark_gray}},
        %Span{content: truncate(message.body, max_body), style: %Style{fg: :white}}
      ]
    }
  end

  @doc "Deterministic color for a username — Alice always cyan, Bob always green, etc."
  @spec user_color(String.t()) :: atom()
  def user_color(user) when is_binary(user) do
    Enum.at(@user_colors, :erlang.phash2(user, length(@user_colors)))
  end

  defp truncate(string, max) when is_binary(string) do
    if String.length(string) > max do
      String.slice(string, 0, max - 1) <> "…"
    else
      string
    end
  end
end
