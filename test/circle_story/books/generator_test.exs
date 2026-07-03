defmodule CircleStory.Books.GeneratorTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Generator
  alias CircleStory.Books.Templates.NanisMagicThread

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
