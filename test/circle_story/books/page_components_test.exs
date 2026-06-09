defmodule CircleStory.Books.PageComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias CircleStory.Books.PageComponents

  test "inner_spread/1 renders a sized page with positioned, colored text" do
    html =
      render_component(&PageComponents.inner_spread/1, %{
        art_uri: "data:image/png;base64,AAAA",
        text: "Meet Ornella.",
        rect: %{x: 300, y: 1300, w: 1200, h: 400},
        align: :left,
        color: "#1A1A1A"
      })

    assert html =~ "width:3675px"
    assert html =~ "height:1875px"
    assert html =~ "Meet Ornella."
    assert html =~ "left:300px"
    assert html =~ "top:1300px"
    assert html =~ "color:#1A1A1A"
    assert html =~ "fit-text"
    assert html =~ "data:image/png;base64,AAAA"
  end

  test "dedication/1 renders cream page, text, and a pink circle" do
    html = render_component(&PageComponents.dedication/1, %{text: "For Ornella."})

    assert html =~ "width:3675px"
    assert html =~ "For Ornella."
    assert html =~ "border-radius:50%"
    assert html =~ "pink"
  end

  test "cover/1 renders all three panels, title/author, tagline, blurb, spine" do
    html =
      render_component(&PageComponents.cover/1, %{
        art_uri: "data:image/png;base64,BBBB",
        rect: %{x: 200, y: 150, w: 1400, h: 500},
        align: :center,
        front_color: "#FAFAFA",
        title: "Nani's Magic Thread",
        author: "Sidd & Veronika",
        tagline: "A story of love.",
        fill: "rgb(180,170,150)",
        ink: "#1A1A1A"
      })

    assert html =~ "width:3863px"
    assert html =~ "Nani&#39;s Magic Thread"
    assert html =~ "Sidd &amp; Veronika"
    assert html =~ "A story of love."
    assert html =~ "Circle Storybooks"
    assert html =~ "www.circlestorybooks.com"
    assert html =~ "rotate(-90deg)"
    assert html =~ "left:1988px"
  end
end
