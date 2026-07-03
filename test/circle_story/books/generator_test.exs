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

      assert %Character{name: "Ornella", reference_image_path: ^path} =
               Book.back_cover_character(updated)
    end

    test "returns an error for an unknown character name", %{book: book} do
      assert {:error, _} = Generator.attach_character_reference(book, "Nobody")
    end

    test "returns the book unchanged when no reference file exists" do
      book = %Book{
        title: "T",
        author: "A",
        characters: [%Character{name: "Zzz", image_prompt: "x"}]
      }

      assert {:ok, ^book} = Generator.attach_character_reference(book, "Zzz")
    end
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
