defmodule CircleStory.Books.Templates.NanisMagicThread do
  alias CircleStory.Books.{Book, Character, CoverSpread, DedicationSpread, InnerSpread}

  @spec book() :: Book.t()
  def book do
    %Book{
      title: "Nani's Magic Thread",
      author: "Sidd & Veronika",
      cover: cover(),
      dedication: dedication(),
      spreads: spreads(),
      characters: characters()
    }
  end

  defp characters do
    [
      %Character{
        name: "Ornella",
        image_prompt: """
        Baby girl, half-Russian, half-Indian, with a bright beautiful smile and light brown/hazel eyes. \
        Chubby, adorable, rosy-cheeked baby with a warm, joyful, wide-eyed expression. Very young \
        toddler age, plump baby proportions.\
        """
      },
      %Character{
        name: "Nani",
        image_prompt: """
        Elder Indian great-grandmother, strong and fierce yet deeply loving. She wears a gold nose ring, \
        a red bindi on her forehead, a pearl necklace, and traditional Indian clothing (saris or salwar \
        kameez) in warm colors — yellows and golds. Silver-white hair. Dignified, powerful, warmly \
        commanding presence with deep expressive eyes.\
        """
      },
      %Character{
        name: "Asha",
        image_prompt: """
        Indian grandmother in her late 50s, highly successful and elegant. Long wavy brown hair and a \
        beautiful, confident smile. Carries herself with the assured authority of a professor, published \
        author, and businesswoman. Sophisticated, strong, radiant.\
        """
      },
      %Character{
        name: "Sidd",
        image_prompt: """
        Indian man (father), warm wide smile, short dark hair. Kind, strong, nurturing. Friendly and \
        approachable with a genuine, loving expression.\
        """
      },
      %Character{
        name: "Veronika",
        image_prompt: """
        Russian woman (mother), beautiful with long flowing brown hair and a warm, radiant smile. \
        Graceful, loving, and elegant.\
        """
      }
    ]
  end

  defp cover do
    %CoverSpread{
      tagline: "A story of love woven through generations.",
      image_prompt: """
      A warm, inviting scene of elder Nani sitting at a vintage black treadle sewing machine, smiling \
      with deep love. Baby Ornella sits nearby on a soft cushion, looking up at her with a bright, \
      delighted smile. Colorful spools of thread in rainbow colors are scattered charmingly around them. \
      Warm golden light fills the cozy room. The composition leaves clear space at the top for the book \
      title overlay. The scene feels magical and intimate — a moment of intergenerational love and wonder.\
      """
    }
  end

  defp dedication do
    %DedicationSpread{
      text:
        "For Ornella — may you always feel the warmth of Nani's love wrapped around you like a golden thread."
    }
  end

  defp spreads do
    [
      spread_1(),
      spread_2(),
      spread_3(),
      spread_4(),
      spread_5(),
      spread_6(),
      spread_7(),
      spread_8(),
      spread_9()
    ]
  end

  defp spread_1 do
    %InnerSpread{
      position: 1,
      text:
        "Meet Ornella. She is a beautiful little girl with a bright smile. She is half-Russian, half-Indian, and entirely made of love.",
      image_prompt: """
      A beautiful, bright portrait of baby Ornella centered on the page. She is joyful and radiant, \
      laughing or smiling broadly. The background subtly blends Indian and Russian cultures — on a \
      nearby shelf, a small colorful Russian matryoshka nesting doll and a small painted Indian elephant \
      figurine sit side by side. Warm, inviting nursery setting. The composition feels celebratory and \
      welcoming, like an introduction to a beloved character.\
      """
    }
  end

  defp spread_2 do
    %InnerSpread{
      position: 2,
      text:
        "Ornella has a very special guardian angel in the stars. We call her Nani. Nani was Ornella's great-grandmother, and she lived far away in India.",
      image_prompt: """
      A whimsical, magical nighttime scene. A deep blue starry sky fills the image with glittering \
      stars and soft glowing clouds. In the clouds above, a gentle, protective, luminous spirit portrait \
      of Nani smiles down with radiant love — rendered as a softly glowing presence, warm and golden. \
      Below, a cozy small house on the earth is warmly lit from within, where little Ornella lives. \
      The composition feels vast yet tender, like a grandmother watching over home from the heavens.\
      """
    }
  end

  defp spread_3 do
    %InnerSpread{
      position: 3,
      text:
        "Nani had magic in her hands. She was a master seamstress! She even ran a big sewing school, teaching everyone how to make beautiful clothes. Click, clack, went her sewing machine all day long.",
      image_prompt: """
      Nani in her bustling sewing school in India. She stands or sits confidently at the center, \
      surrounded by colorful bolts and reams of vibrant fabrics — saris, silks, and rich textiles in \
      jewel tones. She is instructing a group of younger Indian women who are seated attentively at \
      sewing machines. The room is bright, energetic, and bursting with color. Nani's presence is \
      commanding but warm — clearly the master of her craft, in her element.\
      """
    }
  end

  defp spread_4 do
    %InnerSpread{
      position: 4,
      text:
        "Nani was very, very strong. She was the boss of the neighborhood! Everyone listened to her because she was brave, fearless, and protected her family like a fierce lioness.",
      image_prompt: """
      Nani walks through her neighborhood with a commanding, fierce, proud presence. Shopkeepers and \
      neighbors around her greet her with deep respect and warm smiles — bowing heads, hands folded in \
      namaste. Beside her, barely visible like a golden aura or shadow, a friendly silhouette of a \
      majestic lioness walks in perfect step with her, symbolizing her inner strength. The scene is \
      vibrant — a busy, colorful Indian street full of life.\
      """
    }
  end

  defp spread_5 do
    %InnerSpread{
      position: 5,
      text:
        "With that same fierce love, Nani raised Asha, Ornella's Dadi. Guided by Nani's strength, Asha grew up to become a very successful business lady, a brilliant Professor, and an author — a true lioness in her own right!",
      image_prompt: """
      A flowing visual narrative: young Asha as a girl stands proudly beside her mother Nani, who \
      looks at her with fierce, loving pride and a hand on her shoulder. Beside or transitioning from \
      this, adult Asha stands confidently at a university podium as a professor, holding a book she \
      authored, radiating success and power. The visual journey shows Nani's love and strength flowing \
      directly into Asha's greatness. Both women glow with lioness energy.\
      """
    }
  end

  defp spread_6 do
    %InnerSpread{
      position: 6,
      text:
        "When Papa, Sidd, was a little boy, Nani took care of him. To show her deep love, she would make him his absolute favorite food: warm, delicious aloo ka paranthas! She made sure he grew up strong, well-fed, and kind.",
      image_prompt: """
      A warm, nostalgic Indian kitchen scene. A younger Nani stands at the stove, smiling with pure \
      love, flipping a fresh golden aloo ka parantha on a flat tawa pan. Steam rises from the pan. \
      A little boy (young Sidd) sits eagerly at the kitchen table, leaning forward with a huge hungry \
      joyful smile, hands clasped in anticipation. The scene is cozy and golden-lit, full of warmth \
      and the feeling of home and love.\
      """
    }
  end

  defp spread_7 do
    %InnerSpread{
      position: 7,
      text:
        "Then, Nani met Mama, Veronika. From the very first second Nani saw her, she smiled her biggest smile. She loved Mama instantly and wrapped her in a big, warm hug, welcoming her to the family.",
      image_prompt: """
      The beautiful moment of first meeting between Nani and Veronika. Nani has the most massive, \
      radiant, genuine smile on her face — eyes crinkled with joy. She is wrapping Veronika in a huge, \
      warm, enveloping hug — unconditional maternal love made visible. Veronika looks deeply touched, \
      smiling warmly back into the embrace. Sidd may be nearby watching with a happy, full heart. \
      Warm golden indoor light. The scene radiates instant acceptance and belonging.\
      """
    }
  end

  defp spread_8 do
    %InnerSpread{
      position: 8,
      text:
        "Now, Nani is resting in the sky, but she is never far away. She used her magic needle to sew a strong, invisible thread of love that connects Papa, Mama, Asha Dadi, and little Ornella forever.",
      image_prompt: """
      A beautiful symbolic image. In the sky and clouds above, Nani's gentle glowing spirit smiles \
      down serenely, holding a golden glowing needle in her hand. From the needle, a magical luminous \
      golden thread winds downward through the air, weaving gently around and connecting portraits or \
      silhouettes of adult Sidd, adult Veronika, and elegant Asha Dadi below. The thread glows warmly \
      with love. The mood is peaceful, magical, bittersweet, and ultimately full of joy and hope.\
      """
    }
  end

  defp spread_9 do
    %InnerSpread{
      position: 9,
      text:
        "Sleep tight, sweet Ornella. You have the strength of a Russian bear and an Indian lioness inside you, backed by the love of your family and Nani. You are so blessed.",
      image_prompt: """
      Sweet baby Ornella sleeping peacefully in her cozy crib, wrapped in a soft blanket. Beside her \
      crib on a small shelf sit two beloved objects: a colorful Russian matryoshka nesting doll and a \
      small plush Indian elephant toy. Over her blanket, the glowing golden thread of Nani's love rests \
      softly like a warm protective embrace — barely luminous, gently magical. The room is dim and \
      peaceful, bathed in the softest warm golden light. The mood is tender, safe, and deeply loved.\
      """
    }
  end
end
