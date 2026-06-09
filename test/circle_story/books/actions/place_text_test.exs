defmodule CircleStory.Books.Actions.PlaceTextTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Actions.PlaceText

  describe "parse_result/1" do
    test "reads a valid string-keyed map" do
      assert {:ok, %{bounding_box: [150, 680, 480, 950], text_align: :right}} =
               PlaceText.parse_result(%{
                 "bounding_box" => [150, 680, 480, 950],
                 "text_align" => "right"
               })
    end

    test "defaults an unknown alignment to :center" do
      assert {:ok, %{text_align: :center}} =
               PlaceText.parse_result(%{
                 "bounding_box" => [0, 0, 100, 100],
                 "text_align" => "weird"
               })
    end

    test "rejects malformed output" do
      assert {:error, _} =
               PlaceText.parse_result(%{"bounding_box" => [1, 2], "text_align" => "left"})

      assert {:error, _} = PlaceText.parse_result(%{"text_align" => "left"})
      assert {:error, _} = PlaceText.parse_result(:nonsense)
    end
  end

  describe "default_box/1" do
    test "inner vs cover differ" do
      assert %{bounding_box: [_, _, _, _], text_align: :center} = PlaceText.default_box(:inner)
      assert %{bounding_box: [_, _, _, _], text_align: :center} = PlaceText.default_box(:cover)
      refute PlaceText.default_box(:inner) == PlaceText.default_box(:cover)
    end
  end
end
