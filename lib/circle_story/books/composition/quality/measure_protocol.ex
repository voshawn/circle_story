defmodule CircleStory.Books.Composition.Quality.MeasureProtocol do
  @moduledoc false

  import ChromicPDF.ProtocolMacros

  steps do
    include_protocol(ChromicPDF.Navigate)

    call(
      :measure,
      "Runtime.evaluate",
      &%{
        "expression" => Map.fetch!(&1, :measurement_script),
        "awaitPromise" => true,
        "returnByValue" => true
      },
      %{}
    )

    await_response(:measured, [{["result", "value"], "measurements"}])
    include_protocol(ChromicPDF.ResetTarget)
    output("measurements")
  end
end
