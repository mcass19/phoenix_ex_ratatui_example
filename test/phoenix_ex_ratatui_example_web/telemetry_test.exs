defmodule PhoenixExRatatuiExampleWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias PhoenixExRatatuiExampleWeb.Telemetry

  test "metrics/0 returns a list of telemetry metrics" do
    metrics = Telemetry.metrics()
    assert is_list(metrics)
    assert length(metrics) > 0
  end
end
