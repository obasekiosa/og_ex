defmodule OgEx.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/example/og_ex"

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
      files: [
        "lib",
        "native/og_ex_native/src",
        "native/og_ex_native/Cargo.toml",
        "native/og_ex_native/Cargo.lock",
        "mix.exs",
        "README.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      # Use the public module as the stable landing page. README is still
      # included as a full guide in the extras sidebar.
      main: "OgEx",
      extras: ["README.md"] ++ Path.wildcard("docs/*.md")
    ]
  end
end
