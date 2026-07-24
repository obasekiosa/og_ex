defmodule OgEx.TestSvgCard do
  @moduledoc false

  use OgEx.Card,
    width: 600,
    height: 600,
    format: :svg

  @doc """
  Returns deterministic metadata for SVG lifecycle tests.
  """
  @impl OgEx.Card
  def metadata(assigns) do
    %{
      title: assigns.title,
      twitter_card: "summary"
    }
  end

  @doc """
  Returns the title as the SVG fixture's content version.
  """
  @impl OgEx.Card
  def version(assigns), do: assigns.title

  @doc """
  Renders a minimal full-viewport SVG fixture card.
  """
  @impl OgEx.Card
  def render(assigns) do
    ~H"""
    <main class="card">{@title}</main>
    <style>
      .card {
        width: 100%;
        height: 100%;
        display: flex;
        align-items: center;
        background: #1746d1;
        color: white;
        font: 64px sans-serif;
      }
    </style>
    """
  end
end
