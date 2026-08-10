defmodule CircleStory.Books.GeneratorTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.{Book, Character, Generator}
  alias CircleStory.Books.Actions.GenerateCharacterReference
  alias CircleStory.Books.Templates.NanisMagicThread

  describe "attach_character_reference/2" do
    setup do
      dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
      File.mkdir_p!(dir)

      prefix = GenerateCharacterReference.reference_prefix("Ornella")
      path = Path.join(dir, "#{prefix}#{System.unique_integer([:positive])}.png")
      Image.write!(Image.new!(64, 64, color: :pink), path)
      on_exit(fn -> File.rm(path) end)

      book = %Book{
        title: "T",
        author: "A",
        characters: [%Character{name: "Ornella", image_prompt: "baby"}]
      }

      %{book: book, path: path}
    end

    test "attaches the newest saved reference to the named character", %{book: book, path: path} do
      assert {:ok, updated} = Generator.attach_character_reference(book, "Ornella")

      assert [%Character{name: "Ornella", reference_image_path: ^path}] = updated.characters
    end

    test "returns an error for an unknown character name", %{book: book} do
      assert {:error, _} = Generator.attach_character_reference(book, "Nobody")
    end

    test "errors instead of reporting success when no reference file exists" do
      book = %Book{
        title: "T",
        author: "A",
        characters: [%Character{name: "Zzz", image_prompt: "x"}]
      }

      assert {:error, :no_reference_image} = Generator.attach_character_reference(book, "Zzz")
    end
  end

  describe "attach_character_reference/2 prefix anchoring" do
    setup do
      dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
      File.mkdir_p!(dir)

      # "Nani" is a prefix of "Nani Rose". A bare "character_nani_*" glob also
      # matches "character_nani_rose_*", and because 'r' sorts above every digit
      # the *wrong* character wins even though Nani's portrait is newer.
      nani =
        Path.join(dir, "#{GenerateCharacterReference.reference_prefix("Nani")}1786000500.png")

      rose =
        Path.join(
          dir,
          "#{GenerateCharacterReference.reference_prefix("Nani Rose")}1786000100.png"
        )

      Image.write!(Image.new!(8, 8, color: :pink), nani)
      Image.write!(Image.new!(8, 8, color: :blue), rose)
      on_exit(fn -> Enum.each([nani, rose], &File.rm/1) end)

      %{nani: nani, rose: rose}
    end

    test "a shorter name does not pick up a longer name's portrait", %{nani: nani} do
      book = %Book{
        title: "T",
        author: "A",
        characters: [%Character{name: "Nani", image_prompt: "elder"}]
      }

      assert {:ok, updated} = Generator.attach_character_reference(book, "Nani")
      assert [%Character{name: "Nani", reference_image_path: ^nani}] = updated.characters
    end

    test "the longer name still resolves to its own portrait", %{rose: rose} do
      book = %Book{
        title: "T",
        author: "A",
        characters: [%Character{name: "Nani Rose", image_prompt: "mother"}]
      }

      assert {:ok, updated} = Generator.attach_character_reference(book, "Nani Rose")
      assert [%Character{name: "Nani Rose", reference_image_path: ^rose}] = updated.characters
    end
  end

  describe "attach_character_reference/2 non-ASCII names" do
    setup do
      dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
      File.mkdir_p!(dir)

      # The readable part of the filename is a lossy ASCII slug: "José" and "Jos"
      # both slug to "jos", 李明 and 小华 both slug to "". Without a digest of the
      # exact name these pairs share a prefix outright, and the newest file (the
      # *other* character's portrait) wins for both.
      saved =
        Map.new(
          [
            {"José", 1_786_000_100},
            {"Jos", 1_786_000_500},
            {"李明", 1_786_000_100},
            {"小华", 1_786_000_500}
          ],
          fn {name, ts} ->
            path =
              Path.join(dir, "#{GenerateCharacterReference.reference_prefix(name)}#{ts}.png")

            Image.write!(Image.new!(8, 8, color: :pink), path)
            {name, path}
          end
        )

      on_exit(fn -> Enum.each(saved, fn {_name, path} -> File.rm(path) end) end)

      %{saved: saved}
    end

    test "each accented and non-Latin name resolves to its own portrait", %{saved: saved} do
      for {name, path} <- saved do
        book = %Book{
          title: "T",
          author: "A",
          characters: [%Character{name: name, image_prompt: "x"}]
        }

        assert {:ok, updated} = Generator.attach_character_reference(book, name)
        assert [%Character{reference_image_path: ^path}] = updated.characters
      end
    end
  end

  test "generate_character_reference/2 errors for an unknown character name" do
    book = %Book{
      title: "T",
      author: "A",
      characters: [%Character{name: "Ornella", image_prompt: "baby"}]
    }

    assert {:error, _} = Generator.generate_character_reference(book, "Nobody")
  end

  describe "inspect_prompt/2 character selection" do
    test "an inner spread only includes characters it names" do
      book = NanisMagicThread.book()
      {_system, user} = Generator.inspect_prompt(book, 1)

      # Spread 1 is all about Ornella.
      assert user =~ "<ORNELLA>"
      refute user =~ "<NANI>"
      refute user =~ "<ASHA>"
    end

    test "the cover includes the characters named in its art prompt" do
      book = NanisMagicThread.book()
      {_system, user} = Generator.inspect_prompt(book, :cover)

      # Cover art names Nani and baby Ornella, not Asha.
      assert user =~ "<NANI>"
      assert user =~ "<ORNELLA>"
      refute user =~ "<ASHA>"
    end
  end
end
