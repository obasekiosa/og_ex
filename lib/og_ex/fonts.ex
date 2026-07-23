defmodule OgEx.Fonts do
  @moduledoc false

  @doc """
  Loads every configured font into an in-memory binary.

  Configuration entries may be filesystem paths or already-loaded font bytes.
  """
  def load do
    # Each entry may be a path or an already-loaded binary. Binary input is
    # useful for applications that retrieve fonts from object storage or embed
    # them with `@external_resource`.
    :og_ex
    |> Application.get_env(:fonts, [])
    |> Enum.map(&load_font!/1)
  end

  # Resolves an existing path with File.read!/1; otherwise treats the input as
  # the font binary itself. Invalid paths ultimately surface as native font
  # decoding errors.
  defp load_font!(font) when is_binary(font) do
    # Existing paths are read; other binaries are passed through as font data.
    # Configuration validation will eventually make this distinction explicit.
    if File.regular?(font), do: File.read!(font), else: font
  end
end
