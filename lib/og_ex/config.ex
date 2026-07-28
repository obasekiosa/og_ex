defmodule OgEx.Config do
  @moduledoc """
  Normalized configuration for one page's social metadata and image response.

  Applications do not normally construct this struct. OgEx creates it
  internally from either `og: CardModule` or an `og: [...]` direct-image
  declaration. The same value is consumed by head-tag injection, signature
  verification, private-file responses, and generated-card rendering.

  ## Fields

    * `:strategy` selects the response lifecycle. `{:generated, CardModule}`
      renders HEEx with Takumi; `:existing` emits an existing image directly.
    * `:assigns` contains ordinary controller assigns available to a generated
      card. Direct images retain it for a consistent controller boundary.
    * `:metadata` contains normalized Open Graph and Twitter values such as
      `:title`, `:description`, `:image_alt`, and `:twitter_card`.
    * `:version` is a URL-safe content identity used in signatures, ETags, and
      final-image cache keys. It never contains the original assigns.
    * `:image_url` is the absolute Open Graph image URL placed in the document.
    * `:twitter_image_url` is an optional separate Twitter image URL. Metadata
      falls back to `:image_url` when this is nil.
    * `:card` is the generated card module. It is nil for direct images.
    * `:width` and `:height` are generated canvas dimensions or verified direct
      local-image dimensions. They may be nil for a remote direct image when
      the declaration did not provide explicit dimensions.
    * `:format` is the generated output format or the verified local image
      format. It may be nil for remote direct images because OgEx deliberately
      does not fetch those URLs during an HTML request.
    * `:image` is the verified local resource or normalized remote source used
      for Open Graph metadata in the direct-image strategy.
    * `:twitter_image` is the corresponding Twitter resource or source. It is
      the same logical image as `:image` unless `:twitter_image` was declared.

  Generated-card configs use `:card`, dimensions, and format, while their
  `:image` fields remain nil. Direct-image configs use `:image` fields while
  `:card` remains nil. Code consuming this struct should branch on `:strategy`
  rather than infer the strategy from optional fields.
  """

  alias OgEx.Image.{Resource, Source}

  @type strategy :: {:generated, module()} | :existing
  @type direct_image :: Resource.t() | Source.t()

  @type t :: %__MODULE__{
          strategy: strategy(),
          assigns: map(),
          metadata: map(),
          version: String.t(),
          image_url: String.t(),
          card: module() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          format: :png | :jpeg | :webp | :gif | :svg | nil,
          image: direct_image() | nil,
          twitter_image: direct_image() | nil,
          twitter_image_url: String.t() | nil
        }

  @enforce_keys [:strategy, :assigns, :metadata, :version, :image_url]

  defstruct @enforce_keys ++
              [
                :card,
                :width,
                :height,
                :format,
                :image,
                :twitter_image,
                :twitter_image_url
              ]
end
