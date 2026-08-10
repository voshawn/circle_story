defmodule CircleStory.Books.Actions.PlaceTextTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CircleStory.Books.Actions.PlaceText
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response

  @valid_object %{
    "bounding_box" => [150, 680, 480, 950],
    "text_align" => "right",
    "vertical_align" => "top"
  }

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

  describe "parse_response/1" do
    test "recovers valid JSON content when the structured object field is nil" do
      assert fake_response(Jason.encode!(@valid_object)).object == nil

      assert {:ok,
              %{
                bounding_box: [150, 680, 480, 950],
                text_align: :right,
                vertical_align: :top
              }} = PlaceText.parse_response(fake_response(Jason.encode!(@valid_object)))
    end

    test "does not extract JSON concatenated with thought-summary prose" do
      content = "THOUGHT_SUMMARY_SECRET\n#{Jason.encode!(@valid_object)}"

      assert {:error, %ReqLLM.Error.API.Response{reason: reason}} =
               PlaceText.parse_response(fake_response(content))

      assert reason == "Failed to parse JSON from text content"
    end
  end

  describe "run/3" do
    test "preserves model provenance for a valid fake Google response" do
      opts = stub_google(Jason.encode!(@valid_object))

      assert {:ok, result} =
               PlaceText.run(%{image_png: "fake-png", text: "story", mode: :inner}, %{}, opts)

      assert result.source == :model
      assert result.bounding_box == [150, 680, 480, 950]
    end

    test "falls back with provenance and a safe diagnostic for unusable structured output" do
      thought_text = "THOUGHT_SUMMARY_SECRET\n#{Jason.encode!(@valid_object)}"
      opts = stub_google(thought_text)

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   PlaceText.run(
                     %{image_png: "IMAGE_SECRET", text: "PROMPT_SECRET", mode: :cover},
                     %{},
                     opts
                   )

          assert result == Map.put(PlaceText.default_box(:cover), :source, :fallback)
        end)

      assert log =~ "structured output JSON could not be parsed"
      refute log =~ "nil"
      refute log =~ "THOUGHT_SUMMARY_SECRET"
      refute log =~ "PROMPT_SECRET"
      refute log =~ "IMAGE_SECRET"
    end

    test "reports a safe reason instead of nil when structured output is absent" do
      log =
        capture_log(fn ->
          assert {:ok, %{source: :fallback}} =
                   PlaceText.run(
                     %{image_png: "IMAGE_SECRET", text: "PROMPT_SECRET", mode: :inner},
                     %{},
                     stub_google(nil)
                   )
        end)

      assert log =~ "structured output was absent"
      refute log =~ "nil"
      refute log =~ "PROMPT_SECRET"
      refute log =~ "IMAGE_SECRET"
    end
  end

  describe "default_box/1" do
    test "inner vs cover differ" do
      assert %{bounding_box: [_, _, _, _], text_align: :center} = PlaceText.default_box(:inner)
      assert %{bounding_box: [_, _, _, _], text_align: :center} = PlaceText.default_box(:cover)
      refute PlaceText.default_box(:inner) == PlaceText.default_box(:cover)
    end
  end

  defp fake_response(text) do
    %Response{
      id: "fake-response",
      model: PlaceText.model(),
      context: nil,
      object: nil,
      message: %Message{role: :assistant, content: [ContentPart.text(text)]}
    }
  end

  defp stub_google(text) do
    plug = fn conn ->
      body =
        Jason.encode!(%{
          "candidates" => [
            %{
              "content" => %{
                "role" => "model",
                "parts" => if(is_nil(text), do: [], else: [%{"text" => text}])
              },
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 1,
            "candidatesTokenCount" => 1,
            "totalTokenCount" => 2
          }
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end

    [api_key: "test-key", max_retries: 0, req_http_options: [plug: plug]]
  end
end
