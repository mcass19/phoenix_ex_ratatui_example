defmodule PhoenixExRatatuiExample.ApplicationTest do
  @moduledoc """
  Tests for the SSH admin daemon child spec builder.

  These exercise `ssh_admin_child/2` directly with manufactured
  arguments — no `Application.put_env/3`, no real SSH listener, no
  global state. The supervision tree's actual zero-arg call site is
  exercised every time the app boots in any other test.
  """

  use ExUnit.Case, async: true

  alias PhoenixExRatatuiExample.Application, as: PhxApp

  describe "ssh_admin_child/2" do
    test "returns nil when the daemon is disabled" do
      assert PhxApp.ssh_admin_child(false, []) == nil
      assert PhxApp.ssh_admin_child(false, port: 9999) == nil
    end

    test "returns a daemon child spec with sensible defaults when enabled" do
      assert {PhoenixExRatatuiExample.AdminTui, opts} = PhxApp.ssh_admin_child(true, [])

      # `:mod` is injected by ExRatatui.App's generated start_link/1,
      # not by us — the builder only supplies user-facing options.
      refute Keyword.has_key?(opts, :mod)
      assert opts[:transport] == :ssh
      assert opts[:port] == 2222
      assert opts[:auto_host_key] == true
      assert opts[:auth_methods] == ~c"password"
      assert opts[:user_passwords] == [{~c"admin", ~c"admin"}]
    end

    test "user options override the defaults (right wins on Keyword.merge)" do
      {PhoenixExRatatuiExample.AdminTui, opts} =
        PhxApp.ssh_admin_child(true,
          port: 9000,
          user_passwords: [{~c"alice", ~c"s3cret"}]
        )

      assert opts[:port] == 9000
      assert opts[:user_passwords] == [{~c"alice", ~c"s3cret"}]
      # Untouched defaults still flow through.
      assert opts[:transport] == :ssh
      assert opts[:auth_methods] == ~c"password"
    end

    test "explicit :system_dir drops the :auto_host_key default" do
      {PhoenixExRatatuiExample.AdminTui, opts} =
        PhxApp.ssh_admin_child(true, system_dir: ~c"/etc/ex_ratatui/host_keys")

      # The daemon refuses both at once, so the merger has to remove
      # the auto-host-key default whenever the user supplies a dir.
      refute Keyword.has_key?(opts, :auto_host_key)
      assert opts[:system_dir] == ~c"/etc/ex_ratatui/host_keys"
    end

    test "without :system_dir the :auto_host_key default stays in place" do
      {PhoenixExRatatuiExample.AdminTui, opts} =
        PhxApp.ssh_admin_child(true, port: 3333)

      assert opts[:auto_host_key] == true
      refute Keyword.has_key?(opts, :system_dir)
    end
  end

  describe "ssh_admin_child/0" do
    test "respects the :ssh_admin config flag set in config/test.exs" do
      # config/test.exs sets ssh_admin: false, so the supervision tree
      # never starts a real listener during the suite.
      assert PhxApp.ssh_admin_child() == nil
    end
  end

  describe "distributed_admin_child/2" do
    test "returns nil when disabled" do
      assert PhxApp.distributed_admin_child(false, []) == nil
    end

    test "returns a listener child spec with the admin TUI module by default" do
      assert {ExRatatui.Distributed.Listener, opts} = PhxApp.distributed_admin_child(true, [])
      assert opts[:mod] == PhoenixExRatatuiExample.AdminTui
    end

    test "user options merge into the defaults" do
      {ExRatatui.Distributed.Listener, opts} =
        PhxApp.distributed_admin_child(true, app_opts: [extra: :yes])

      assert opts[:mod] == PhoenixExRatatuiExample.AdminTui
      assert opts[:app_opts] == [extra: :yes]
    end
  end
end
