defmodule CircleStory.Books.PromptBuilder do
  alias CircleStory.Books.Character

  @master_style_core """
                     Style: Children's book \
                     illustration inspired by Antoine de Saint-Exupéry's The Little Prince, modernized \
                     with bolder, more saturated colors. Watercolor and gouache painting style with \
                     delicate ink linework — loose, expressive, and slightly whimsical. Soft, blended \
                     color washes with smooth gradients. Characters have simple, charming proportions \
                     with expressive faces rendered in minimal, confident lines. Color palette: Warm and \
                     vibrant but still soft — rich golden yellows, deep sky blues, blush pinks, sage \
                     greens, terracotta, and creamy off-whites. Colors should feel sun-drenched and \
                     emotionally warm, not pastel or washed out. Backgrounds feature gentle color washes \
                     or open negative space to keep focus on the characters. Composition: Storybook \
                     layouts with a sense of openness and air. Soft, dreamy lighting. Clean linework \
                     with a handmade, timeless quality. Smooth finish suitable for high-quality print \
                     reproduction. Mood: Tender, nostalgic, joyful, and gently magical — like a modern \
                     classic.\
                     """
                     |> String.trim()

  @inner_system_prompt """
                       You are generating inner page spreads for a children's book. You should follow \
                       this Master Style for every image generation <MASTER STYLE> #{@master_style_core} \
                       Avoid: Photorealism, 3D rendering, anime, sharp digital lines, neon colors, \
                       busy backgrounds, generic AI "storybook" aesthetic, paper texture, canvas texture, \
                       grainy or rough surfaces, visible brushstrokes, scanned-art look, book spines, \
                       page edges, gutters, fold lines, center creases, white borders, any book anatomy. \
                       Do not include any story text in the artwork. Text is only acceptable on objects \
                       in the image. </MASTER STYLE> You will be provided with a SCENE prompt as well as \
                       one or more CHARACTERS prompts. You may also receive reference images for the scene \
                       and characters. Your job is to compose all of these prompts and images into a well \
                       designed page for a book. IMPORTANT: Generate a full-bleed illustration that fills the entire image \
                       edge to edge, with no white borders. Compose with the main subject placed off-center toward one \
                       side or corner — never dead center — leaving the opposite area calm and uncluttered with soft, \
                       simple background washes and open negative space. Keep backgrounds clean and unbusy. Do not render any text.
                       """
                       |> String.trim()

  @cover_system_prompt """
                       You are generating the front cover artwork for a children's board book. You should \
                       follow this Master Style for every image generation <MASTER STYLE> #{@master_style_core} \
                       Avoid: Photorealism, 3D rendering, anime, \
                       sharp digital lines, neon colors, busy backgrounds, generic AI "storybook" aesthetic, \
                       paper texture, canvas texture, grainy or rough surfaces, visible brushstrokes, \
                       scanned-art look. </MASTER STYLE> You will be provided with a SCENE prompt and \
                       CHARACTER prompts. Compose a compelling front cover image. IMPORTANT: Do not render \
                       any text, letters, words, or typography anywhere in the image — no title, no author \
                       name, no labels of any kind. The book title and author name will be overlaid \
                       separately in post-production. Leave clear space at the top for text overlay. Design \
                       with a strong focal point featuring the main character, with an inviting, eye-catching \
                       composition suitable for a children's board book cover.
                       """
                       |> String.trim()

  @character_system_prompt """
                           You are generating a single character reference portrait for a children's \
                           book. You should follow this Master Style for every image generation \
                           <MASTER STYLE> #{@master_style_core} Avoid: Photorealism, 3D rendering, anime, \
                           sharp digital lines, neon colors, busy backgrounds, generic AI "storybook" \
                           aesthetic, paper texture, canvas texture, grainy or rough surfaces, visible \
                           brushstrokes, scanned-art look. </MASTER STYLE> You will be provided with one \
                           CHARACTER prompt, and you may receive a reference photo of the real person. \
                           Generate a clean, appealing reference portrait of this single character alone, \
                           centered in the frame, from roughly the waist up (or a full figure for a baby \
                           or toddler), with a calm, friendly expression. Place the character on a soft, \
                           plain, uncluttered background wash in the master-style palette so the figure \
                           can be cleanly cropped into a circle. Do not include any other characters, \
                           props, scenery, text, letters, or words. If a reference photo is provided, \
                           capture that person's likeness — face shape, features, hair, and skin tone — \
                           while rendering them fully in the master illustration style.
                           """
                           |> String.trim()

  @spec system_prompt(:inner | :cover | :character) :: String.t()
  def system_prompt(:inner), do: @inner_system_prompt
  def system_prompt(:cover), do: @cover_system_prompt
  def system_prompt(:character), do: @character_system_prompt

  @spec user_message(struct(), [Character.t()]) :: String.t()
  def user_message(spread, []), do: "<SCENE>\n#{spread.image_prompt}\n</SCENE>"

  def user_message(spread, characters) do
    scene_block = "<SCENE>\n#{spread.image_prompt}\n</SCENE>"
    chars_inner = build_characters_inner(characters)
    "#{scene_block}\n<CHARACTERS>\n#{chars_inner}\n</CHARACTERS>"
  end

  @doc "The single-character block used when generating a reference portrait."
  @spec character_message(Character.t()) :: String.t()
  def character_message(%Character{name: name, image_prompt: prompt}),
    do: char_block(name, prompt)

  defp build_characters_inner(characters) do
    characters
    |> Enum.map(fn %Character{name: name, image_prompt: prompt} -> char_block(name, prompt) end)
    |> Enum.join("\n")
  end

  defp char_block(name, prompt) do
    tag = String.upcase(name)
    "<#{tag}>\n#{prompt}\n</#{tag}>"
  end
end
