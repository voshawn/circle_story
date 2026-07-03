defmodule CircleStory.Books.Actions.GeminiImageTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Actions.GeminiImage

  describe "build_messages/2" do
    test "returns a plain-text user message when there are no images" do
      assert GeminiImage.build_messages("hello", []) == [%{role: "user", content: "hello"}]
    end

    test "embeds image parts as base64 data URLs alongside the text" do
      [msg] = GeminiImage.build_messages("scene", [{"rawbytes", "image/png"}])
      assert %{role: "user", content: [text_part | image_parts]} = msg
      assert text_part == %{type: "text", text: "scene"}
      assert [%{type: "image_url", image_url: %{url: url}}] = image_parts
      assert url == "data:image/png;base64,#{Base.encode64("rawbytes")}"
    end
  end

  describe "mime_type/1" do
    test "maps known extensions (case-insensitively)" do
      assert GeminiImage.mime_type("a.png") == "image/png"
      assert GeminiImage.mime_type("a.JPG") == "image/jpeg"
      assert GeminiImage.mime_type("a.jpeg") == "image/jpeg"
      assert GeminiImage.mime_type("a.webp") == "image/webp"
    end

    test "defaults unknown or missing extensions to image/jpeg" do
      assert GeminiImage.mime_type("a.gif") == "image/jpeg"
      assert GeminiImage.mime_type("noext") == "image/jpeg"
    end
  end
end
