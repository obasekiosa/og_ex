defmodule OgEx.Native do
  @moduledoc false

  use Rustler, otp_app: :og_ex, crate: "og_ex_native"

  @doc """
  Renders HTML through the native Takumi NIF.

  This Elixir body is a fallback that raises only when the native library could
  not be loaded. Rustler replaces it when the module loads successfully.
  """
  def render_html(_html, _options), do: :erlang.nif_error(:nif_not_loaded)
end
