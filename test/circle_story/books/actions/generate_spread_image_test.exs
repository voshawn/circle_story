defmodule CircleStory.Books.Actions.GenerateSpreadImageTest do
  use ExUnit.Case

  alias CircleStory.Books.{Character, InnerSpread}
  alias CircleStory.Books.Actions.GenerateSpreadImage
  alias CircleStory.CharacterSelectorProviderFake

  test "space-free CJK selection preserves the prompt block and reference-image conditioning" do
    fixture_dir =
      Path.join(System.tmp_dir!(), "spread_request_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(fixture_dir)
    reference_path = Path.join(fixture_dir, "li_ming.png")
    File.write!(reference_path, "li-ming-reference-bytes")
    on_exit(fn -> File.rm_rf(fixture_dir) end)

    li_ming = %Character{
      name: "李明",
      image_prompt: "a curious child in a yellow raincoat",
      reference_image_path: reference_path
    }

    other = %Character{name: "Asha", image_prompt: "a professor"}
    spread = %InnerSpread{position: 1, text: "李明走进花园", image_prompt: "a sunny garden"}
    send(self(), {:character_selector_response, {:ok, ["李明"]}})

    request =
      GenerateSpreadImage.build_request(spread, [li_ming, other], :inner,
        provider: CharacterSelectorProviderFake,
        cache_dir: Path.join(fixture_dir, "selection_cache")
      )

    assert_receive {:character_selector_called, ^spread, ["李明", "Asha"]}
    assert request.selected_characters == [li_ming]

    {:ok, context} = ReqLLM.Context.normalize(request.messages, [])
    [user] = context.messages
    text = Enum.find(user.content, &(&1.type == :text))
    image = Enum.find(user.content, &(&1.type == :image))

    assert text.text =~ "<李明>"
    assert text.text =~ "a curious child in a yellow raincoat"
    refute text.text =~ "<ASHA>"
    assert image.data == "li-ming-reference-bytes"
    assert image.media_type == "image/png"
  end

  @tag :integration
  test "generates an image and saves it to disk" do
    spread = %InnerSpread{
      position: 1,
      text: "Mama comes home.",
      image_prompt: """
      A heart-melting daycare pickup moment. Christine (Mama) is opening the door to \
      the daycare room, kneeling with arms open. Chloe runs toward her at full toddler \
      speed — arms wide, pigtails bouncing, mouth open in a joyful squeal. Cozy daycare \
      classroom, warm afternoon light streaming through a window.
      """
    }

    characters = [
      %Character{
        name: "Chloe",
        image_prompt: """
        Chloe, a toddler girl, approximately 1.5–2 years old. East Asian features with \
        warm light skin and a round baby face. Large expressive dark brown eyes. Black hair \
        in two high pigtails tied with small bows. Cozy ribbed knit sweater in warm peach/blush.
        """
      },
      %Character{
        name: "Christine",
        image_prompt: """
        Christine, a young woman in her early-to-mid 30s. South East Asian features with \
        warm light skin. Long black slightly wavy hair. Cozy cream knit sweater. Warm, \
        loving expression.
        """
      }
    ]

    assert {:ok, %{image_path: path}} =
             Jido.Exec.run(
               GenerateSpreadImage,
               %{
                 spread: spread,
                 characters: characters,
                 spread_type: :inner
               },
               %{}
             )

    assert File.exists?(path)
    assert Path.extname(path) in [".png", ".jpg", ".jpeg", ".webp"]

    IO.puts("Generated image saved to: #{path}")
  end
end
