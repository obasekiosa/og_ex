defmodule OgEx.Renderer.Takumi do
  @moduledoc """
  Native Takumi implementation of `OgEx.Renderer`.

  Filesystem and HTTP work happen before this module is called. The renderer
  receives verified image buffers under the source strings used in the HTML.
  Native layout and encoding run on Rustler's dirty CPU scheduler.
  """

  @behaviour OgEx.Renderer

  @doc """
  Renders an HTML document using Takumi.

  Options:

    * `:width` — required viewport width
    * `:height` — required viewport height
    * `:format` — `:png`, `:jpeg`, `:webp`, or `:svg`; defaults to `:png`
    * `:fonts` — loaded font binaries; defaults to an empty list
    * `:images` — source strings mapped to encoded image bytes; defaults to an
      empty map

  Takumi requires at least one valid font for generated-card rendering.
  """
  @impl true
  def render(html, options) when is_binary(html) and is_list(options) do
    # Keep the NIF boundary small and stable: one HTML binary and one map of
    # primitive values. This also makes alternate native implementations easy.
    native_options = %{
      width: Keyword.fetch!(options, :width),
      height: Keyword.fetch!(options, :height),
      format: Keyword.get(options, :format, :png),
      fonts: Keyword.get(options, :fonts, []),
      images: Keyword.get(options, :images, %{})
    }

    OgEx.Native.render_html(html, native_options)
  end
end
