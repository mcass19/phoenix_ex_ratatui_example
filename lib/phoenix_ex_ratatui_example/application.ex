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
        # In-memory chat room the LiveView and the admin TUI both consume.
        # Lives in front of the endpoint so the PubSub it broadcasts on
        # is already up.
        PhoenixExRatatuiExample.Chat,
        # Admin TUI exposed over SSH + distribution.
        ssh_admin_child(),
        distributed_admin_child(),
        PhoenixExRatatuiExampleWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixExRatatuiExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Returns the SSH admin daemon child spec, or `nil` to skip starting
  # it in the current environment. The defaults below give the demo a
  # one-`ssh`-away setup; override `:ssh_admin_opts` from config to
  # change anything (port, auth method, system_dir, etc).
  @doc false
  def ssh_admin_child do
    ssh_admin_child(
      Application.get_env(:phoenix_ex_ratatui_example, :ssh_admin, true),
      Application.get_env(:phoenix_ex_ratatui_example, :ssh_admin_opts, [])
    )
  end

  @doc false
  # Pure two-arg form so tests can drive the merge logic without
  # touching `Application.put_env/3`. The zero-arg version above is
  # the only thing the supervision tree calls.
  def ssh_admin_child(false, _user_opts), do: nil

  def ssh_admin_child(true, user_opts) when is_list(user_opts) do
    defaults = [
      transport: :ssh,
      port: 2222,
      auto_host_key: true,
      auth_methods: ~c"password",
      user_passwords: [{~c"admin", ~c"admin"}]
    ]

    # Drop the auto-host-key default when the user supplies an
    # explicit `:system_dir` — the daemon refuses both at once.
    defaults =
      if Keyword.has_key?(user_opts, :system_dir) do
        Keyword.delete(defaults, :auto_host_key)
      else
        defaults
      end

    # `{Mod, opts}` flows through `ExRatatui.App.dispatch_start/1`,
    # which routes `transport: :ssh` to `ExRatatui.SSH.Daemon` with
    # `:mod` injected from the module name. Right wins on Keyword.merge,
    # so user-supplied options override defaults.
    {PhoenixExRatatuiExample.AdminTui, Keyword.merge(defaults, user_opts)}
  end

  # Returns the distributed-listener child spec, or `nil` to skip.
  # Uses `ExRatatui.Distributed.Listener` directly (instead of going
  # through `dispatch_start/1`) so the child spec ID doesn't collide
  # with the SSH daemon child above — both wrap the same app module.
  @doc false
  def distributed_admin_child do
    distributed_admin_child(
      Application.get_env(:phoenix_ex_ratatui_example, :distributed_admin, true),
      Application.get_env(:phoenix_ex_ratatui_example, :distributed_admin_opts, [])
    )
  end

  @doc false
  def distributed_admin_child(false, _user_opts), do: nil

  def distributed_admin_child(true, user_opts) when is_list(user_opts) do
    defaults = [mod: PhoenixExRatatuiExample.AdminTui]
    {ExRatatui.Distributed.Listener, Keyword.merge(defaults, user_opts)}
  end
end
