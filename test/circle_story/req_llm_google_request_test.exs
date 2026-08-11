defmodule CircleStory.ReqLLMGoogleRequestTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Google

  @api_opts [api_key: "test-key", google_thinking_level: :medium]

  test "Google object requests suppress thought summaries without changing chat or image requests" do
    {:ok, compiled_schema} =
      ReqLLM.Schema.compile(value: [type: :string, required: true])

    object_config =
      generation_config(:object, "google:gemini-3.1-flash-lite", compiled_schema: compiled_schema)

    chat_config = generation_config(:chat, "google:gemini-3.1-flash-lite")
    image_config = generation_config(:image, "google:gemini-3.1-flash-image")

    assert object_config[:responseMimeType] == "application/json"
    assert object_config[:thinkingConfig][:thinkingLevel] == "medium"
    assert object_config[:thinkingConfig][:includeThoughts] == false

    assert chat_config[:thinkingConfig][:includeThoughts] == true
    assert image_config[:thinkingConfig][:includeThoughts] == true
  end

  defp generation_config(operation, model, extra_opts \\ []) do
    opts = Keyword.merge(@api_opts, extra_opts)
    {:ok, request} = Google.prepare_request(operation, model, "test prompt", opts)

    request
    |> Google.encode_body()
    |> then(& &1.options[:json][:generationConfig])
  end
end
