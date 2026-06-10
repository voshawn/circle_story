defmodule CircleStory.Books.Composition.Fonts do
  @moduledoc """
  Reads the vendored TTFs in `priv/fonts` and emits base64 `@font-face` rules so
  the render document is fully self-contained (no fontconfig, no static-serving).
  The CSS is built once and cached in a module attribute at compile time.
  """

  @fonts [
    %{family: "Fredoka", file: "Fredoka.ttf", style: "normal"},
    %{family: "Nunito", file: "Nunito.ttf", style: "normal"},
    %{family: "Nunito", file: "Nunito-Italic.ttf", style: "italic"}
  ]

  # Recompile this module if any vendored TTF changes (the CSS bakes them in at compile time).
  for %{file: file} <- @fonts do
    @external_resource Path.join([:code.priv_dir(:circle_story), "fonts", file])
  end

  @font_face_css (for %{family: family, file: file, style: style} <- @fonts do
                    path = Path.join([:code.priv_dir(:circle_story), "fonts", file])
                    base64 = path |> File.read!() |> Base.encode64()

                    """
                    @font-face {
                      font-family: '#{family}';
                      font-style: #{style};
                      font-weight: 100 900;
                      src: url(data:font/ttf;base64,#{base64}) format('truetype');
                    }
                    """
                  end)
                 |> Enum.join("\n")

  @doc "All `@font-face` rules (Fredoka, Nunito, Nunito italic) with embedded base64 TTFs."
  @spec font_face_css() :: String.t()
  def font_face_css, do: @font_face_css
end
