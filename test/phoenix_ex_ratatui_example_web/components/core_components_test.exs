defmodule PhoenixExRatatuiExampleWeb.CoreComponentsTest do
  use PhoenixExRatatuiExampleWeb.ConnCase, async: true

  alias PhoenixExRatatuiExampleWeb.CoreComponents

  test "translate_error/1 interpolates opts into the message" do
    assert CoreComponents.translate_error({"must be at least %{count} characters", count: 3}) ==
             "must be at least 3 characters"
  end

  test "translate_error/1 returns the message as-is when no opts match" do
    assert CoreComponents.translate_error({"is invalid", []}) == "is invalid"
  end
end
