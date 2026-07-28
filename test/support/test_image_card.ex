defmodule OgEx.TestImageCard do
  @moduledoc false

  use OgEx.Card, width: 320, height: 180

  @impl OgEx.Card
  @doc """
  Returns metadata for the generated resource-loading fixture.
  """
  def metadata(_assigns), do: %{title: "Image resource"}

  @impl OgEx.Card
  @doc """
  Renders a generated card containing a Phoenix public static image.
  """
  def render(assigns) do
    ~H"""
    <main style="width: 320px; height: 180px; background: #fff">
      <img src="/images/og-ex-test.svg" width="64" height="32" />
    </main>
    """
  end
end
