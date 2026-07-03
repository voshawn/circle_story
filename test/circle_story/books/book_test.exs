defmodule CircleStory.Books.BookTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.{Book, Character}

  test "back_cover_character/1 returns the first character" do
    a = %Character{name: "Ornella", image_prompt: "baby"}
    b = %Character{name: "Nani", image_prompt: "elder"}
    book = %Book{title: "T", author: "A", characters: [a, b]}

    assert Book.back_cover_character(book) == a
  end

  test "back_cover_character/1 returns nil when there are no characters" do
    book = %Book{title: "T", author: "A", characters: []}
    assert Book.back_cover_character(book) == nil
  end

  test "Character carries an optional source_image_path" do
    c = %Character{name: "Ornella", image_prompt: "baby", source_image_path: "x.jpg"}
    assert c.source_image_path == "x.jpg"
    assert c.reference_image_path == nil
  end
end
