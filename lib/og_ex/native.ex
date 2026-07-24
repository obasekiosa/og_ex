defmodule OgEx.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :og_ex,
    crate: "og_ex_native",
    base_url: "https://github.com/obasekiosa/og_ex/releases/download/v#{version}",
    force_build: System.get_env("OG_EX_BUILD") in ["1", "true"],
    nif_versions: ["2.15"],
    targets: [
      "aarch64-unknown-linux-gnu",
      "aarch64-unknown-linux-musl",
      "aarch64-apple-darwin",
      "x86_64-apple-darwin",
      "x86_64-unknown-linux-gnu",
      "x86_64-unknown-linux-musl",
      "x86_64-pc-windows-msvc"
    ],
    version: version

  @doc """
  Renders HTML through the native Takumi NIF.

  This Elixir body is a fallback that raises only when the native library could
  not be loaded. Rustler replaces it when the module loads successfully.
  """
  def render_html(_html, _options), do: :erlang.nif_error(:nif_not_loaded)
end
