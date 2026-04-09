defmodule PhoenixExRatatuiExample.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PhoenixExRatatuiExampleWeb.Telemetry,
        {DNSCluster,
         query: Application.get_env(:phoenix_ex_ratatui_example, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: PhoenixExRatatuiExample.PubSub},
        # In-memory chat room that the LiveView and the SSH admin TUI
        # both consume. Lives in front of the endpoint so the PubSub it
        # broadcasts on is already up.
        PhoenixExRatatuiExample.Chat,
        # Optional admin TUI exposed over SSH. Disabled in :test (no
        # network listener during the suite) and may be disabled in
        # other environments via `config :phoenix_ex_ratatui_example,
        # :ssh_admin, false`.
        ssh_admin_child(),
        PhoenixExRatatuiExampleWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixExRatatuiExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhoenixExRatatuiExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Returns the child spec for the SSH admin TUI, or nil if it should
  # not be started in the current environment. Kept here so the
  # supervision tree's intent stays readable.
  defp ssh_admin_child do
    if Application.get_env(:phoenix_ex_ratatui_example, :ssh_admin, true) do
      ssh_opts =
        Application.get_env(:phoenix_ex_ratatui_example, :ssh_admin_opts, [])
        |> Keyword.put_new(:port, 2222)

      {PhoenixExRatatuiExample.AdminTui.SSH, ssh_opts}
    end
  end
end
