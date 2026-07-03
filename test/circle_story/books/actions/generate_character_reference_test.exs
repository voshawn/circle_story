defmodule CircleStory.Books.Actions.GenerateCharacterReferenceTest do
  use ExUnit.Case

  alias CircleStory.Books.Character
  alias CircleStory.Books.Actions.GenerateCharacterReference

  describe "reference_prefix/1" do
    test "slugifies the character name" do
      assert GenerateCharacterReference.reference_prefix("Ornella") == "character_ornella_"
    end

    test "collapses spaces and punctuation to single underscores" do
      assert GenerateCharacterReference.reference_prefix("Nani Ji!") == "character_nani_ji_"
    end
  end

  @tag :integration
  test "generates a reference portrait and saves it to disk" do
    character = %Character{
      name: "Ornella",
      image_prompt: "A joyful, rosy-cheeked baby girl with a bright smile and hazel eyes."
    }

    assert {:ok, %{image_path: path}} =
             GenerateCharacterReference.run(%{character: character}, %{})

    assert File.exists?(path)
    assert Path.basename(path) =~ ~r/^character_ornella_\d+\.png$/
    IO.puts("Generated character reference saved to: #{path}")
  end
end
