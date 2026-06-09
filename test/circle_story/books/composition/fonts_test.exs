defmodule CircleStory.Books.Composition.FontsTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.Fonts

  test "font_face_css/0 embeds both families as base64 truetype" do
    css = Fonts.font_face_css()
    assert css =~ "font-family: 'Fredoka'"
    assert css =~ "font-family: 'Nunito'"
    assert css =~ "font-style: italic"
    assert css =~ "data:font/ttf;base64,"
    assert css =~ "format('truetype')"
  end
end
