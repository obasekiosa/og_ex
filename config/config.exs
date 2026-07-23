import Config

config :og_ex,
  cache: OgEx.Cache.ETS,
  renderer: OgEx.Renderer.Takumi,
  token_max_age: 31_536_000
