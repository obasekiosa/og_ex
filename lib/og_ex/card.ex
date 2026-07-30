defmodule OgEx.Card do
  @moduledoc """
  Behaviour and setup macro for generated social cards.

  A card implements `metadata/1` and `render/1`, and normally implements
  `version/1`. `use OgEx.Card` imports `Phoenix.Component`, so card modules can
  return ordinary HEEx:

      defmodule MyAppWeb.ArticleOgCard do
        use OgEx.Card, width: 1200, height: 630, format: :png

        @impl OgEx.Card
        def metadata(%{article: article}) do
          %{title: article.title, description: article.summary}
        end

        @impl OgEx.Card
        def version(%{article: article}) do
          {:article_card, 1, article.id, article.updated_at}
        end

        @impl OgEx.Card
        def render(assigns) do
          ~H"<main style=\"width: 100%; height: 100%\">{@article.title}</main>"
        end
      end

  The README includes complete generated, embedded-local, and embedded-external
  card modules together with their actual image outputs.
  """

  @type metadata :: %{
          required(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:type) => String.t(),
          optional(:image_alt) => String.t(),
          optional(:twitter_card) => String.t()
        }

  @doc """
  Returns metadata for the page and generated image.

  `:title` is required. `:description`, `:type`, `:image_alt`, and
  `:twitter_card` are optional.
  """
  @callback metadata(assigns :: map()) :: metadata()

  @doc """
  Returns the HEEx representation sent to the configured renderer.

  The callback receives the controller assigns passed beside `:og`. Image
  sources in `<img src>` are loaded before the renderer is called.
  """
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Returns stable content data used to version the generated image.

  This callback is optional. When omitted, OgEx versions the complete assigns
  map. Implement it in production to exclude assigns that do not affect the
  image.

  Card source, HEEx, and CSS are not hashed automatically. A conventional
  return value is `{:article_card, layout_revision, content_data...}`. The
  label and revision belong to the application; they are not the OgEx package
  version. Increase the revision when a presentation-only change must create a
  new immutable URL and cache entry.
  """
  @callback version(assigns :: map()) :: term()

  @doc """
  Loads assigns for a standalone image request.

  The callback receives the image request connection and normalized route
  parameters. Use `OgEx.controller/1`, `OgEx.action/1`, and
  `OgEx.image_role/1` when one card serves several declarations.

  A declaration-specific `load:` function overrides this callback.
  """
  @callback load(conn :: Plug.Conn.t(), params :: map()) ::
              {:ok, map()}
              | {:error, :not_found | :forbidden | :unavailable | term()}

  @optional_callbacks version: 1, load: 2

  @doc """
  Configures a module as an OgEx card.

  Options:

    * `:width` — viewport width in pixels; defaults to `1200`
    * `:height` — viewport height in pixels; defaults to `630`
    * `:format` — `:png`, `:jpeg`, `:webp`, or `:svg`; defaults to `:png`

  The macro imports `Phoenix.Component`, records the rendering options, and
  installs the `OgEx.Card` behaviour.
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
