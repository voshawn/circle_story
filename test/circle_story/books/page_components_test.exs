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

  test "inner_spread/1 renders the selected safety inset and font cap with transparent text" do
    html =
      render_component(&PageComponents.inner_spread/1, %{
        art_uri: "data:image/png;base64,AAAA",
        text: "Safe text",
        rect: %{x: 300, y: 200, w: 900, h: 400},
        align: :center,
        valign: :top,
        color: "#1A1A1A",
        text_inset: 48,
        text_min_font: 18,
        text_max_font: 56
      })

    assert html =~ "left:48px;right:48px;top:48px;bottom:48px"
    assert html =~ ~s(data-min-font="18")
    assert html =~ ~s(data-max-font="56")
    refute html =~ "background:rgba"
  end

  test "cover/1 applies the selected font floor to the front panel only" do
    html =
      render_component(&PageComponents.cover/1, %{
        art_uri: "data:image/png;base64,BBBB",
        rect: %{x: 200, y: 150, w: 1400, h: 500},
        align: :center,
        front_color: "#FAFAFA",
        title: "T",
        author: "A",
        tagline: "A story of love.",
        fill: "rgb(1,2,3)",
        ink: "#1A1A1A",
        text_min_font: 18
      })

    assert html =~ ~s(data-min-font="18")
    # The back-panel tagline is not a searched candidate and keeps the page floor.
    assert html =~ ~s(data-min-font="24")
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

  test "dedication/1 renders the user's photo in the circle when given a URI" do
    html =
      render_component(&PageComponents.dedication/1, %{
        text: "For Ornella.",
        dedication_uri: "data:image/png;base64,DEDI"
      })

    assert html =~ "border-radius:50%"
    assert html =~ "data:image/png;base64,DEDI"
    assert html =~ "object-fit:cover"
    refute html =~ "background:pink"
  end

  test "dedication/1 keeps the pink placeholder when no URI is given" do
    html = render_component(&PageComponents.dedication/1, %{text: "For Ornella."})
    assert html =~ "background:pink"
    refute html =~ "<img"
  end

  test "cover/1 renders the character reference in the back circle when given a URI" do
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
        ink: "#1A1A1A",
        character_uri: "data:image/png;base64,CHAR"
      })

    assert html =~ "data:image/png;base64,CHAR"
    assert html =~ "object-fit:cover"
    refute html =~ "background:pink"
  end

  test "cover/1 keeps the pink placeholder when no character URI is given" do
    html =
      render_component(&PageComponents.cover/1, %{
        art_uri: "data:image/png;base64,BBBB",
        rect: %{x: 200, y: 150, w: 1400, h: 500},
        align: :center,
        front_color: "#FAFAFA",
        title: "T",
        author: "A",
        tagline: "t",
        fill: "rgb(1,2,3)",
        ink: "#1A1A1A"
      })

    assert html =~ "background:pink"
  end

  test "the printed page, the fit sheet, and the scored mask render one role body" do
    candidate = %{
      id: "candidate-0",
      rect: %{x: 0, y: 0, w: 900, h: 400},
      align: :center,
      valign: :middle,
      min_font: 24,
      max_font: 360,
      inset: 48
    }

    cover_content = %{title: "Nani's Magic Thread", author: "Sidd & Veronika"}

    page =
      render_component(&PageComponents.cover/1, %{
        art_uri: "data:image/png;base64,BBBB",
        rect: candidate.rect,
        align: :center,
        front_color: "#FAFAFA",
        title: cover_content.title,
        author: cover_content.author,
        tagline: "A story of love.",
        fill: "rgb(180,170,150)",
        ink: "#1A1A1A"
      })

    sheet =
      render_component(&PageComponents.quality_sheet/1, %{
        candidates: [candidate],
        content: cover_content,
        role: :cover
      })

    mask =
      render_component(&PageComponents.quality_mask/1, %{
        candidate: candidate,
        content: cover_content,
        role: :cover
      })

    assert role_body(page) == role_body(sheet)
    assert role_body(page) == role_body(mask)
    assert role_body(page) =~ "font-size:0.5em;margin-top:0.18em"

    inner_content = %{text: "Meet Ornella."}

    inner_page =
      render_component(&PageComponents.inner_spread/1, %{
        art_uri: "data:image/png;base64,AAAA",
        text: inner_content.text,
        rect: candidate.rect,
        align: :center,
        color: "#1A1A1A"
      })

    inner_mask =
      render_component(&PageComponents.quality_mask/1, %{
        candidate: candidate,
        content: inner_content,
        role: :inner
      })

    assert role_body(inner_page) == role_body(inner_mask)
    assert role_body(inner_page) =~ "Meet Ornella."
  end

  # The last `.fit-inner` is the front-panel/candidate text; the pipeline's
  # guarantee is that all three surfaces render it identically.
  defp role_body(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".fit-inner")
    |> Enum.map(&(&1 |> LazyHTML.child_nodes() |> LazyHTML.to_html()))
    |> List.last()
    |> String.trim()
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
