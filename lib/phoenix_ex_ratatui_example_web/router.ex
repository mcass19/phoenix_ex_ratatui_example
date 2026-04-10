defmodule PhoenixExRatatuiExampleWeb.Router do
  use PhoenixExRatatuiExampleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PhoenixExRatatuiExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", PhoenixExRatatuiExampleWeb do
    pipe_through :browser

    live "/", ChatLive, :index
  end

  if Application.compile_env(:phoenix_ex_ratatui_example, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PhoenixExRatatuiExampleWeb.Telemetry
    end
  end
end
