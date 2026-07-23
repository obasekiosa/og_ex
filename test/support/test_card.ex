defmodule OgEx.TestCard do
  @moduledoc false

  use OgEx.Card, width: 1200, height: 630

  @impl OgEx.Card
  def metadata(%{title: title}) do
    %{
      title: title,
      description: "A generated social card",
      image_alt: "Card for #{title}"
    }
  end

  # A small explicit version keeps cache and token tests independent from
  # unrelated assigns that a real controller might pass to its page template.
  @impl OgEx.Card
  def version(%{title: title}), do: title

  @impl OgEx.Card
  def render(assigns) do
    ~H"""
    <main class="card">
      <h1>{@title}</h1>
    </main>

    <style>
      .card {
        width: 1200px;
        height: 630px;
        display: flex;
        align-items: center;
        justify-content: center;
        color: white;
        background: #312e81;
        font-family: sans-serif;
      }

      h1 {
        font-size: 72px;
      }
    </style>
    """
  end
end
