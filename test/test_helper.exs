ExUnit.start()

# The native renderer intentionally does not depend on host-installed fonts.
# Tests point it at a well-known font available in the development container.
# Production applications configure their own brand fonts the same way.
font =
  Enum.find(
    [
      "/usr/share/fonts/opentype/urw-base35/NimbusSans-Regular.otf",
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
      "/Library/Fonts/Arial.ttf"
    ],
    &File.regular?/1
  )

if font do
  Application.put_env(:og_ex, :fonts, [font])
end
