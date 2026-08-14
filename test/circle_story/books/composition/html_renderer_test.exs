defmodule CircleStory.Books.Composition.HtmlRendererTest do
  # async: false — the debug-toggle test mutates application env.
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition.HtmlRenderer

  test "component_to_html/1 renders a function component to a string" do
    assigns = %{name: "World"}

    component = fn assigns ->
      import Phoenix.Component
      ~H"<p>Hello {@name}</p>"
    end

    assert HtmlRenderer.component_to_html(component.(assigns)) == "<p>Hello World</p>"
  end

  test "document/1 wraps page html with fonts, reset, fit-script and data-ready hook" do
    doc = HtmlRenderer.document("<div>PAGE</div>")

    assert doc =~ "<!DOCTYPE html>"
    assert doc =~ "@font-face"
    assert doc =~ "<div>PAGE</div>"
    assert doc =~ "fit-text"
    assert doc =~ "data-ready"
    assert doc =~ "document.fonts.ready"
    assert doc =~ "margin:0"
  end

  test "document/1 toggles the red debug outline via :debug_bounding_boxes" do
    prev = Application.get_env(:circle_story, :debug_bounding_boxes, false)
    on_exit(fn -> Application.put_env(:circle_story, :debug_bounding_boxes, prev) end)

    Application.put_env(:circle_story, :debug_bounding_boxes, false)
    refute HtmlRenderer.document("<div>P</div>") =~ "outline: 6px solid red"

    Application.put_env(:circle_story, :debug_bounding_boxes, true)
    assert HtmlRenderer.document("<div>P</div>") =~ ".fit-text { outline: 6px solid red"
  end

  @tag :integration
  test "to_png/3 screenshots a page to an exact-size PNG" do
    # Sandbox-less for the same reason as the composition quality tests: Ubuntu
    # 23.10+ blocks Chrome's namespace sandbox via AppArmor.
    start_supervised!({ChromicPDF, no_sandbox: true})

    page = ~s(<div style="width:400px;height:200px;background:teal"></div>)
    out = Path.join(System.tmp_dir!(), "hr_#{System.unique_integer([:positive])}.png")

    assert {:ok, ^out} = HtmlRenderer.to_png(page, {400, 200}, out)
    img = Image.open!(out)
    assert Image.width(img) == 400
    assert Image.height(img) == 200
  end
end
