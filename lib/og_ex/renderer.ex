defmodule OgEx.Renderer do
  @moduledoc """
  Behaviour for HTML-to-image rendering backends.

  OgEx passes a complete HTML document, viewport dimensions, output format,
  loaded font bytes, and a map of verified image resources. A renderer must
  return a complete encoded response body rather than raw pixels.
  """

  @type option ::
          {:width, pos_integer()}
          | {:height, pos_integer()}
          | {:format, :png | :jpeg | :webp | :svg}
          | {:fonts, [binary()]}
          | {:images, %{optional(String.t()) => binary()}}

  @doc """
  Converts a complete HTML document into an encoded image.

  Implementations must return bytes in the requested output format rather than
  raw RGBA pixels. Expected failures return `{:error, reason}`.
  """
  @callback render(html :: binary(), [option()]) ::
              {:ok, binary()} | {:error, term()}
end
