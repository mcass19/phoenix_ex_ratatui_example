defmodule PhoenixExRatatuiExample.AdminTui.SSHTest do
  @moduledoc """
  Validates the keyword list we hand to `ExRatatui.SSH.Daemon` and
  the host-key bootstrap. We never open a real SSH listener here —
  ex_ratatui already has end-to-end coverage of that, and the
  application config disables the daemon during the suite.
  """

  use ExUnit.Case, async: true

  alias PhoenixExRatatuiExample.AdminTui.SSH

  describe "build_opts/1" do
    test "fills in defaults: mod, port, password auth, system_dir" do
      tmp = tmp_dir!()
      opts = SSH.build_opts(system_dir: tmp)

      assert opts[:mod] == PhoenixExRatatuiExample.AdminTui
      assert opts[:port] == 2222
      assert opts[:auth_methods] == ~c"password"
      assert opts[:user_passwords] == [{~c"admin", ~c"admin"}]
      assert opts[:system_dir] == String.to_charlist(tmp)
    end

    test "respects custom port and credentials" do
      tmp = tmp_dir!()

      opts =
        SSH.build_opts(
          port: 9090,
          ssh_user: ~c"ops",
          ssh_password: ~c"hunter2",
          system_dir: tmp
        )

      assert opts[:port] == 9090
      assert opts[:user_passwords] == [{~c"ops", ~c"hunter2"}]
    end

    test "non-overridden caller opts are forwarded" do
      tmp = tmp_dir!()
      opts = SSH.build_opts(system_dir: tmp, idle_time: :infinity)
      assert opts[:idle_time] == :infinity
    end
  end

  describe "ensure_host_key!/1" do
    test "creates a fresh PEM-encoded RSA private key on first call" do
      dir = tmp_dir!()
      result = SSH.ensure_host_key!(dir)

      key_path = Path.join(dir, "ssh_host_rsa_key")
      assert File.exists?(key_path)
      assert result == String.to_charlist(dir)
      assert File.read!(key_path) =~ "BEGIN RSA PRIVATE KEY"
    end

    test "is idempotent — does not regenerate if a key already exists" do
      dir = tmp_dir!()
      _ = SSH.ensure_host_key!(dir)
      key_path = Path.join(dir, "ssh_host_rsa_key")
      stat1 = File.stat!(key_path)

      # Sleep a tick? No — file mtime resolution is fine, just check
      # the contents stay byte-identical.
      contents1 = File.read!(key_path)
      _ = SSH.ensure_host_key!(dir)
      contents2 = File.read!(key_path)

      assert contents1 == contents2
      assert File.stat!(key_path).size == stat1.size
    end
  end

  describe "child_spec/1" do
    test "returns a worker spec that points at ExRatatui.SSH.Daemon" do
      tmp = tmp_dir!()
      spec = SSH.child_spec(system_dir: tmp)

      assert spec.id == SSH
      assert spec.type == :worker
      assert spec.restart == :transient
      assert {ExRatatui.SSH.Daemon, :start_link, [opts]} = spec.start
      assert opts[:mod] == PhoenixExRatatuiExample.AdminTui
    end
  end

  defp tmp_dir! do
    dir =
      Path.join([
        System.tmp_dir!(),
        "phoenix_ex_ratatui_example_ssh_test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
