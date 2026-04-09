defmodule PhoenixExRatatuiExample.AdminTui.SSH do
  @moduledoc """
  Thin wrapper around `ExRatatui.SSH.Daemon` that wires the admin TUI
  into the application supervision tree with sane dev defaults.

  Responsibilities:

    * Ensure a host key exists under `priv/ssh/` (auto-generated on
      first boot via OTP `:public_key.generate_key/1`).
    * Configure password authentication (`admin` / `admin`) so the
      example works without an `~/.ssh/authorized_keys` setup. **Do
      not** ship this configuration as-is — it's deliberately weak
      so the demo is one `ssh` away from working.
    * Start `ExRatatui.SSH.Daemon` with `mod: PhoenixExRatatuiExample.AdminTui`.

  Override anything via `config :phoenix_ex_ratatui_example, :ssh_admin_opts, [...]`
  in `config/config.exs`. The supervised entry in `Application` reads
  that key and merges it on top of the defaults below.
  """

  require Logger

  alias ExRatatui.SSH.Daemon

  @default_port 2222
  @default_user ~c"admin"
  @default_password ~c"admin"

  @doc """
  Child spec for the supervisor. Accepts the same options as
  `ExRatatui.SSH.Daemon.start_link/1`; everything not provided
  is filled in with the dev defaults documented in the moduledoc.
  """
  def child_spec(opts) do
    opts = build_opts(opts)

    %{
      id: __MODULE__,
      start: {Daemon, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @doc false
  # Public so the test can poke at it without going through the
  # supervisor. Returns the keyword list that will be passed verbatim
  # to ExRatatui.SSH.Daemon.start_link/1.
  def build_opts(opts) do
    system_dir =
      case Keyword.get(opts, :system_dir) do
        nil -> ensure_host_key!()
        dir when is_binary(dir) -> String.to_charlist(dir)
        dir when is_list(dir) -> dir
      end

    port = Keyword.get(opts, :port, @default_port)
    user = Keyword.get(opts, :ssh_user, @default_user)
    password = Keyword.get(opts, :ssh_password, @default_password)

    base = [
      mod: PhoenixExRatatuiExample.AdminTui,
      port: port,
      system_dir: system_dir,
      auth_methods: ~c"password",
      user_passwords: [{user, password}]
    ]

    opts
    |> Keyword.drop([:system_dir, :port, :ssh_user, :ssh_password])
    |> Keyword.merge(base)
  end

  @doc false
  # Generates a fresh RSA host key under priv/ssh/ if one isn't
  # already there, and returns the directory as a charlist (the shape
  # OTP `:ssh.daemon/2` expects).
  def ensure_host_key!(dir \\ default_host_key_dir()) do
    File.mkdir_p!(dir)
    key_path = Path.join(dir, "ssh_host_rsa_key")

    unless File.exists?(key_path) do
      Logger.info("Generating SSH host key at #{key_path}")
      generate_rsa_host_key!(key_path)
    end

    String.to_charlist(dir)
  end

  defp default_host_key_dir do
    :phoenix_ex_ratatui_example
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("ssh")
  end

  defp generate_rsa_host_key!(path) do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
    pem = :public_key.pem_encode([pem_entry])
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end
end
