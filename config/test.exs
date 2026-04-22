import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :phoenix_ex_ratatui_example, PhoenixExRatatuiExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "s5HKeZZBQEywetIU2lLCtHj0MKiK4D88ecRU+L0EgFr70kW48L6VpK12bqS5QCSm",
  server: false

# Don't open an SSH listener or distribution listener during the
# suite — tests drive the admin TUI directly via ExRatatui's
# :test_mode backend.
config :phoenix_ex_ratatui_example, :ssh_admin, false
config :phoenix_ex_ratatui_example, :distributed_admin, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
