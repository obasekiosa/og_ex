defmodule OgEx.Renderer.Takumi do
  @moduledoc """
  Renders HEEx-produced HTML and CSS with the native Takumi engine.
  """

  @behaviour OgEx.Renderer

  @doc """
  Renders an HTML document using Takumi.

  Required options are `:width` and `:height`. `:format` defaults to `:png`,
  and `:fonts` accepts a list of loaded font binaries.
  """
  @impl true
  def render(html, options) when is_binary(html) and is_list(options) do
    # Keep the NIF boundary small and stable: one HTML binary and one map of
    # primitive values. This also makes alternate native implementations easy.
    native_options = %{
      width: Keyword.fetch!(options, :width),
      height: Keyword.fetch!(options, :height),
      format: Keyword.get(options, :format, :png),
      fonts: Keyword.get(options, :fonts, [])
    }

    OgEx.Native.render_html(html, native_options)
  end
end
