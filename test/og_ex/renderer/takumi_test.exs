defmodule OgEx.Renderer.TakumiTest do
  use ExUnit.Case, async: true

  test "renders HTML and a style block into a correctly sized PNG" do
    html = """
    <main class="card">Hello from OgEx</main>
    <style>
      .card {
        width: 1200px;
        height: 630px;
        display: flex;
        align-items: center;
        justify-content: center;
        background: #312e81;
        color: white;
        font: 72px sans-serif;
      }
    </style>
    """

    assert {:ok, png} =
             OgEx.Renderer.Takumi.render(
               html,
               width: 1200,
               height: 630,
               format: :png,
               fonts: OgEx.Fonts.load()
             )

    # PNG files start with an eight-byte signature followed by the IHDR chunk.
    # IHDR stores width and height as big-endian unsigned 32-bit integers.
    assert <<137, "PNG\r\n", 26, "\n", 13::32, "IHDR", 1200::32, 630::32, _rest::binary>> =
             png
  end

  test "returns an explicit error when no font is configured" do
    assert {:error, reason} =
             OgEx.Renderer.Takumi.render(
               "<div>Hello</div>",
               width: 1200,
               height: 630,
               format: :png,
               fonts: []
             )

    assert reason =~ "no fonts configured"
  end
end
