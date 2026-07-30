defmodule OgEx.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/obasekiosa/og_ex"

  def project do
    [
      app: :og_ex,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Embedded Open Graph and Twitter card rendering for Phoenix",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {OgEx.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:plug, "~> 1.15"},
      {:floki, "~> 0.36"},
      {:req, "~> 0.5"},
      {:rustler_precompiled, "~> 0.9"},
      {:rustler, "~> 0.38", runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  # Test-only endpoint and card fixtures are compiled as regular modules so
  # lifecycle tests exercise the same macros and behaviours as consuming apps.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        [
          "lib",
          "native/og_ex_native/src",
          "native/og_ex_native/Cargo.toml",
          "native/og_ex_native/Cargo.lock",
          "native/og_ex_native/.cargo",
          "artifacts",
          "docs/function-reference.md",
          "docs/internal-architecture.md",
          "docs/native-releases.md",
          "mix.exs",
          "README.md",
          "LICENSE"
        ] ++ Path.wildcard("checksum-*.exs")
    ]
  end

  defp docs do
    [
      # HexDocs should expose stable user and maintainer guides. Early API
      # explorations remain in the repository but do not belong in the
      # published documentation sidebar.
      main: "OgEx",
      assets: %{"artifacts/examples" => "artifacts/examples"},
      extras: [
        "README.md",
        "docs/function-reference.md",
        "docs/internal-architecture.md",
        "docs/native-releases.md"
      ],
      groups_for_extras: [
        Guides: ["README.md", "docs/function-reference.md"],
        Maintainers: ["docs/internal-architecture.md", "docs/native-releases.md"]
      ],
      groups_for_modules: [
        "Controller API": [OgEx, OgEx.Controller, OgEx.Card, OgEx.Router],
        "Image API": [OgEx.Image, OgEx.Image.Source, OgEx.Image.Resource],
        "Extension points": [
          OgEx.Renderer,
          OgEx.Renderer.Takumi,
          OgEx.ResourceLoader,
          OgEx.ResourceLoader.Default,
          OgEx.ResourceLoader.Remote,
          OgEx.Cache,
          OgEx.Cache.ETS
        ],
        "Runtime internals": [OgEx.Config, OgEx.Resources, OgEx.ResourceCache]
      ],
      skip_undefined_reference_warnings_on: ["docs/internal-architecture.md"]
    ]
  end
end
