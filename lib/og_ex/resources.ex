defmodule OgEx.Resources do
  @moduledoc """
  Discovers and loads image resources referenced by generated card HTML.

  The renderer receives only verified byte buffers keyed by the exact source
  strings used in the HTML.
  """

  @doc """
  Loads every unique `<img src>` found in a rendered card document.

  Returns the renderer image map and a sorted fingerprint list suitable for a
  generated-image cache key.
  """
  def load(html, conn) when is_binary(html) do
    with {:ok, document} <- Floki.parse_document(html) do
      document
      |> Floki.find("img[src]")
      |> Enum.flat_map(&Floki.attribute(&1, "src"))
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, %{}, []}, &load_source(&1, conn, &2))
      |> finish()
    else
      {:error, reason} -> {:error, {:invalid_card_html, reason}}
    end
  end

  # Normalizes and loads one source, retaining the original HTML value as the
  # Takumi registry key.
  defp load_source(source, conn, {:ok, images, fingerprints}) do
    with {:ok, normalized} <- OgEx.Image.normalize(source, conn),
         {:ok, resource} <- OgEx.Image.load(normalized) do
      {:cont,
       {:ok, Map.put(images, source, resource.bytes), [resource.fingerprint | fingerprints]}}
    else
      {:error, reason} -> {:halt, {:error, {:image_resource, source, reason}}}
    end
  end

  # Sorts fingerprints so cache identity is independent of DOM traversal order.
  defp finish({:ok, images, fingerprints}),
    do: {:ok, images, Enum.sort(fingerprints)}

  defp finish(error), do: error
end
