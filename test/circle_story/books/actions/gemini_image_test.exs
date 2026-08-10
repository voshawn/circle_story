defmodule CircleStory.Books.Actions.GeminiImageTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Actions.GeminiImage

  describe "build_messages/2" do
    test "returns a plain-text user message when there are no images" do
      assert GeminiImage.build_messages("hello", []) == [%{role: "user", content: "hello"}]
    end

    test "image parts survive ReqLLM.Context.normalize as text + image content" do
      # Regression: the message parts must use a shape ReqLLM.Context.normalize
      # actually preserves. A mixed atom-key/string-value map (e.g.
      # %{type: "image_url", ...}) is silently dropped to [], so the image never
      # reaches the model. Assert at the normalization boundary that matters.
      messages = GeminiImage.build_messages("scene", [{"rawbytes", "image/png"}])
      {:ok, ctx} = ReqLLM.Context.normalize(messages, [])
      [user] = ctx.messages

      types = Enum.map(user.content, & &1.type)
      assert :text in types
      assert :image in types or :image_url in types
      assert Enum.any?(user.content, &(&1.type == :text and &1.text == "scene"))
    end
  end

  describe "save/2" do
    test "writes the binary under priv/generated_images and returns the path" do
      filename = "gemini_image_save_test_#{System.unique_integer([:positive])}.png"

      on_exit(fn ->
        File.rm(Path.join([:code.priv_dir(:circle_story), "generated_images", filename]))
      end)

      assert {:ok, path} = GeminiImage.save("rawbytes", filename)
      assert Path.basename(path) == filename
      assert File.read!(path) == "rawbytes"
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
