defmodule CircleStory.Books.CharacterSelector.GeminiTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.CharacterSelector.Gemini
  alias CircleStory.Books.InnerSpread

  @spread %InnerSpread{position: 1, text: "李明走进花园", image_prompt: "a sunny garden"}
  @candidates ["李明", "Asha"]

  defp stub(status, body) do
    test = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:gemini_request, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    [api_key: "test-key", max_retries: 0, req_http_options: [plug: plug]]
  end

  defp object_payload(object) do
    %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => Jason.encode!(object)}]},
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 1,
        "candidatesTokenCount" => 1,
        "totalTokenCount" => 2
      }
    }
  end

  test "selects a space-free CJK name from a Gemini structured-output payload" do
    opts = stub(200, object_payload(%{"character_names" => ["李明"]}))

    assert Gemini.select(@spread, @candidates, opts) == {:ok, ["李明"]}
  end

  test "returns an empty selection when the model references no candidate" do
    opts = stub(200, object_payload(%{"character_names" => []}))

    assert Gemini.select(@spread, @candidates, opts) == {:ok, []}
  end

  test "sends the minimal thinking level and the candidate-constrained schema" do
    opts = stub(200, object_payload(%{"character_names" => ["李明"]}))

    assert {:ok, _} = Gemini.select(@spread, @candidates, opts)
    assert_receive {:gemini_request, body}

    generation_config = body["generationConfig"]

    assert generation_config["thinkingConfig"]["thinkingLevel"] == "minimal"

    schema =
      generation_config["responseJsonSchema"] || generation_config["responseSchema"]

    assert schema["properties"]["character_names"]["items"]["enum"] == @candidates

    prompt =
      body["contents"]
      |> Enum.flat_map(& &1["parts"])
      |> Enum.map_join("", & &1["text"])

    assert prompt =~ ~s(CANDIDATE_NAMES: ["李明","Asha"])
    assert prompt =~ ~s(STORY_TEXT: "李明走进花园")
    assert prompt =~ ~s(IMAGE_PROMPT: "a sunny garden")
  end

  test "an API error is reported as a selection error" do
    opts = stub(503, %{"error" => %{"message" => "service unavailable"}})

    assert {:error, _reason} = Gemini.select(@spread, @candidates, opts)
  end

  test "a payload missing character_names is reported as a selection error" do
    opts = stub(200, object_payload(%{"names" => ["李明"]}))

    assert {:error, _reason} = Gemini.select(@spread, @candidates, opts)
  end
end
