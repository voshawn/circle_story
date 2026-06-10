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
    # Body text is capped so the autofit can't blow it up to fill a large box.
    assert html =~ ~s(data-max-font="64")
  end

  test "inner_spread/1 honors the vertical anchor (valign)" do
    base = %{
      art_uri: "data:image/png;base64,AAAA",
      text: "Hi",
      rect: %{x: 1, y: 1, w: 1, h: 1},
      align: :left,
      color: "#1A1A1A"
    }

    # Default is vertical-centered.
    assert render_component(&PageComponents.inner_spread/1, base) =~ "justify-content:center"
    # AI can anchor to the top to avoid a subject lower in the box.
    top = render_component(&PageComponents.inner_spread/1, Map.put(base, :valign, :top))
    assert top =~ "justify-content:flex-start"
  end

  test "inner_spread/1 renders the raw-AI debug box only when debug_rect is set" do
    base = %{
      art_uri: "data:image/png;base64,AAAA",
      text: "Hi",
      rect: %{x: 1, y: 1, w: 1, h: 1},
      align: :left,
      color: "#1A1A1A"
    }

    refute render_component(&PageComponents.inner_spread/1, base) =~ "dashed #00BFFF"

    html =
      render_component(
        &PageComponents.inner_spread/1,
        Map.put(base, :debug_rect, %{x: 10, y: 20, w: 300, h: 100})
      )

    assert html =~ "dashed #00BFFF"
    assert html =~ "left:10px"
    assert html =~ "AI"
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
