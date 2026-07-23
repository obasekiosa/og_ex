defmodule OgEx.Renderer do
  @moduledoc """
  Behaviour implemented by HTML-to-image rendering backends.
  """

  @type option ::
          {:width, pos_integer()}
          | {:height, pos_integer()}
          | {:format, :png | :jpeg | :webp}
          | {:fonts, [binary()]}

  @doc """
  Converts a complete HTML document into an encoded image binary.

  Implementations must return bytes in the requested output format rather than
  raw RGBA pixels.
  """
  @callback render(html :: binary(), [option()]) ::
              {:ok, binary()} | {:error, term()}
end
