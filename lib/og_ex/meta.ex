defmodule OgEx.Meta do
  @moduledoc false

  @doc """
  Encodes a card configuration as escaped Open Graph and Twitter/X tags.

  Missing optional metadata is omitted; required image dimensions and default
  card types are always included.
  """
  def to_html(config) do
    metadata = config.metadata

    # Phoenix.HTML.Tag constructs and escapes every attribute. Metadata may
    # originate in user-authored database content and must never be concatenated
    # into the page as raw HTML.
    [
      meta(property: "og:title", content: metadata.title),
      optional_meta(metadata[:description], property: "og:description"),
      meta(property: "og:type", content: metadata[:type] || "website"),
      meta(property: "og:image", content: config.image_url),
      meta(property: "og:image:width", content: config.width),
      meta(property: "og:image:height", content: config.height),
      optional_meta(metadata[:image_alt], property: "og:image:alt"),
      meta(name: "twitter:card", content: metadata[:twitter_card] || "summary_large_image"),
      meta(name: "twitter:title", content: metadata.title),
      optional_meta(metadata[:description], name: "twitter:description"),
      meta(name: "twitter:image", content: config.image_url),
      optional_meta(metadata[:image_alt], name: "twitter:image:alt")
    ]
    |> Enum.reject(&is_nil/1)
    # Safe values are joined only after escaping, then converted once at the
    # boundary where Head injects them into the already-rendered document.
    |> Phoenix.HTML.Safe.to_iodata()
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  # phoenix_html 4 intentionally has a smaller public tag API than older
  # releases. Attribute names here are library-owned constants, while every
  # dynamic value is escaped through Phoenix.HTML before concatenation.
  # Encodes one void meta element. Attribute names are library constants and
  # all dynamic values pass through Phoenix.HTML escaping.
  defp meta(attributes) do
    encoded_attributes =
      Enum.map_join(attributes, " ", fn {name, value} ->
        escaped_value =
          value
          |> to_string()
          |> Phoenix.HTML.html_escape()
          |> Phoenix.HTML.safe_to_string()

        "#{name}=\"#{escaped_value}\""
      end)

    Phoenix.HTML.raw("<meta #{encoded_attributes}>")
  end

  # Omits a metadata element when its optional value was not provided.
  defp optional_meta(nil, _attributes), do: nil

  # Adds a content attribute and delegates to the common safe tag encoder.
  defp optional_meta(value, attributes), do: meta(Keyword.put(attributes, :content, value))
end
