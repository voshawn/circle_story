defmodule CircleStory.Books.Actions.GenerateSpreadImageTest do
  use ExUnit.Case

  alias CircleStory.Books.{Character, InnerSpread}
  alias CircleStory.Books.Actions.GenerateSpreadImage

  @moduletag :skip

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
