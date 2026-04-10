defmodule PhoenixExRatatuiExampleWeb.ConnCase do
  @moduledoc """
  Test case for tests that require setting up a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint PhoenixExRatatuiExampleWeb.Endpoint

      use PhoenixExRatatuiExampleWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PhoenixExRatatuiExampleWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
