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
        # Admin TUI exposed over SSH. `auto_host_key: true` lets the
        # daemon generate an RSA host key under `priv/ssh/` on first
        # boot — see `ExRatatui.SSH.Daemon` for the full options list.
        # The whole child can be disabled (e.g. in :test) via
        # `config :phoenix_ex_ratatui_example, :ssh_admin, false`.
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

  # Returns the SSH admin daemon child spec, or `nil` to skip starting
  # it in the current environment. The defaults below give the demo a
  # one-`ssh`-away setup; override `:ssh_admin_opts` from config to
  # change anything (port, auth method, system_dir, etc).
  defp ssh_admin_child do
    if Application.get_env(:phoenix_ex_ratatui_example, :ssh_admin, true) do
      defaults = [
        mod: PhoenixExRatatuiExample.AdminTui,
        port: 2222,
        auto_host_key: true,
        auth_methods: ~c"password",
        user_passwords: [{~c"admin", ~c"admin"}]
      ]

      user_opts = Application.get_env(:phoenix_ex_ratatui_example, :ssh_admin_opts, [])

      # Drop the auto-host-key default when the user supplies an
      # explicit `:system_dir` — the daemon refuses both at once.
      defaults =
        if Keyword.has_key?(user_opts, :system_dir) do
          Keyword.delete(defaults, :auto_host_key)
        else
          defaults
        end

      # Keyword.merge: right wins → user-supplied options override defaults.
      opts = Keyword.merge(defaults, user_opts)

      {ExRatatui.SSH.Daemon, opts}
    end
  end
end
