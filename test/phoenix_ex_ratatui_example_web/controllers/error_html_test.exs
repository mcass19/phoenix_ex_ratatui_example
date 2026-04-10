defmodule PhoenixExRatatuiExampleWeb.ErrorHTMLTest do
  use PhoenixExRatatuiExampleWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    assert render_to_string(PhoenixExRatatuiExampleWeb.ErrorHTML, "404", "html", []) ==
             "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(PhoenixExRatatuiExampleWeb.ErrorHTML, "500", "html", []) ==
             "Internal Server Error"
  end

  test "render/2 returns status message from template" do
    assert PhoenixExRatatuiExampleWeb.ErrorHTML.render("503.html", %{}) ==
             "Service Unavailable"
  end
end
