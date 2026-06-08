defmodule CircleStory.Books.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.{Character, CoverSpread, InnerSpread, PromptBuilder}

  describe "system_prompt/1" do
    test "returns a non-empty string for :inner" do
      prompt = PromptBuilder.system_prompt(:inner)
      assert is_binary(prompt)
      assert String.length(prompt) > 100
      assert prompt =~ "inner page spreads"
    end

    test "returns a non-empty string for :cover" do
      prompt = PromptBuilder.system_prompt(:cover)
      assert is_binary(prompt)
      assert String.length(prompt) > 100
      assert prompt =~ "front cover"
    end

    test ":inner and :cover prompts are different" do
      refute PromptBuilder.system_prompt(:inner) == PromptBuilder.system_prompt(:cover)
    end
  end

  describe "user_message/2" do
    setup do
      spread = %InnerSpread{
        position: 1,
        text: "Mama comes home.",
        image_prompt: "A heart-melting daycare pickup moment."
      }

      characters = [
        %Character{
          name: "Chloe",
          image_prompt: "A toddler girl with pigtails and rosy cheeks."
        },
        %Character{
          name: "Christine",
          image_prompt: "A young woman with long black hair and a warm smile."
        }
      ]

      %{spread: spread, characters: characters}
    end

    test "includes the spread image_prompt in a SCENE block", %{
      spread: spread,
      characters: characters
    } do
      msg = PromptBuilder.user_message(spread, characters)
      assert msg =~ "<SCENE>"
      assert msg =~ "A heart-melting daycare pickup moment."
      assert msg =~ "</SCENE>"
    end

    test "wraps characters in a CHARACTERS block", %{spread: spread, characters: characters} do
      msg = PromptBuilder.user_message(spread, characters)
      assert msg =~ "<CHARACTERS>"
      assert msg =~ "</CHARACTERS>"
    end

    test "each character gets an uppercased name tag", %{spread: spread, characters: characters} do
      msg = PromptBuilder.user_message(spread, characters)
      assert msg =~ "<CHLOE>"
      assert msg =~ "A toddler girl with pigtails"
      assert msg =~ "</CHLOE>"
      assert msg =~ "<CHRISTINE>"
      assert msg =~ "A young woman with long black hair"
      assert msg =~ "</CHRISTINE>"
    end

    test "works with a CoverSpread too", %{characters: characters} do
      cover = %CoverSpread{
        tagline: "Every day, you choose me.",
        image_prompt: "A sun-drenched meadow scene with the main character."
      }

      msg = PromptBuilder.user_message(cover, characters)
      assert msg =~ "<SCENE>"
      assert msg =~ "A sun-drenched meadow scene"
      assert msg =~ "</SCENE>"
    end
  end
end
