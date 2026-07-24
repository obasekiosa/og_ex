defmodule OgEx.Card do
  @moduledoc """
  Defines a social card using HEEx, HTML, and CSS.

  A card implements `metadata/1` and `render/1`. Using this module also imports
  `Phoenix.Component`, so `~H` and component attributes are available.
  """

  @type metadata :: %{
          required(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:type) => String.t(),
          optional(:image_alt) => String.t(),
          optional(:twitter_card) => String.t()
        }

  @doc """
  Returns Open Graph and Twitter/X metadata for the card assigns.
  """
  @callback metadata(assigns :: map()) :: metadata()

  @doc """
  Returns the HEEx representation that OgEx sends to the configured renderer.
  """
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Returns the stable data used to version the generated image.

  This callback is optional. When omitted, OgEx versions the complete assigns
  map.
  """
  @callback version(assigns :: map()) :: term()

  @optional_callbacks version: 1

  @doc """
  Configures a module as an OgEx card.

  Supported options are `:width`, `:height`, and `:format`. Formats may be
  `:png`, `:jpeg`, `:webp`, or `:svg`. The macro imports `Phoenix.Component`,
  records the render dimensions, and installs the `OgEx.Card` behaviour.
  """
  defmacro __using__(options) do
    width = Keyword.get(options, :width, 1200)
    height = Keyword.get(options, :height, 630)
    format = Keyword.get(options, :format, :png)

    quote bind_quoted: [width: width, height: height, format: format] do
      @behaviour OgEx.Card
      use Phoenix.Component

      @og_ex_width width
      @og_ex_height height
      @og_ex_format format

      @doc "Returns the configured card width in pixels."
      def __og_ex__(:width), do: @og_ex_width

      @doc "Returns the configured card height in pixels."
      def __og_ex__(:height), do: @og_ex_height

      @doc "Returns the configured encoded image format."
      def __og_ex__(:format), do: @og_ex_format
    end
  end
end
