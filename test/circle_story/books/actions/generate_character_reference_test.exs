defmodule CircleStory.Books.Actions.GenerateCharacterReferenceTest do
  use ExUnit.Case

  alias CircleStory.Books.Character
  alias CircleStory.Books.Actions.GenerateCharacterReference

  describe "reference_prefix/1" do
    test "slugifies the character name" do
      assert GenerateCharacterReference.reference_prefix("Ornella") =~
               ~r/^character_ornella_[0-9a-f]{8}_$/
    end

    test "collapses spaces and punctuation to single underscores" do
      assert GenerateCharacterReference.reference_prefix("Nani Ji!") =~
               ~r/^character_nani_ji_[0-9a-f]{8}_$/
    end

    test "is stable for the same name" do
      assert GenerateCharacterReference.reference_prefix("Ornella") ==
               GenerateCharacterReference.reference_prefix("Ornella")
    end

    test "distinct names never share a prefix, including non-ASCII ones" do
      # The ASCII slug drops accents entirely ("José" -> "jos") and non-Latin
      # scripts completely (李明 -> ""), so the slug alone collides.
      for {a, b} <- [{"José", "Jos"}, {"Zoë", "Zoé"}, {"李明", "小华"}] do
        refute GenerateCharacterReference.reference_prefix(a) ==
                 GenerateCharacterReference.reference_prefix(b)
      end
    end

    test "stays ASCII and filesystem-safe for non-Latin names" do
      prefix = GenerateCharacterReference.reference_prefix("李明")

      assert prefix =~ ~r{^[a-z0-9_]+$}
      refute prefix =~ ~r{[/\\]}
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
    prefix = GenerateCharacterReference.reference_prefix("Ornella")
    assert Path.basename(path) =~ ~r/^#{Regex.escape(prefix)}\d+\.png$/
    IO.puts("Generated character reference saved to: #{path}")
  end
end
