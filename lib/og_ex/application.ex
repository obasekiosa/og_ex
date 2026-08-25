defmodule OgEx.Flags do
  @moduledoc false

  # Named ETS table backing once-per-node gates (currently the deprecated
  # legacy-signature warning in OgEx.ConfigBuilder). Created by
  # OgEx.Application at boot; see `ensure_flags_table/0`.
end

defmodule OgEx.Application do
  @moduledoc false

  use Application

  @doc """
  Starts the OgEx supervision tree.

  The initial supervision tree owns the default ETS image cache.
  """
  @impl true
  def start(_type, _args) do
    # The default cache lives inside the OgEx supervision tree so applications
    # get a working local cache without adding their own child specification.
    #
    # Renderers are deliberately not processes. The Takumi renderer executes on
    # Rustler's dirty CPU scheduler and can therefore be called concurrently.
    warn_for_global_remote_access()
    warn_for_trailing_slash_canonicalization()
    ensure_flags_table()

    children = [
      OgEx.Cache.ETS,
      OgEx.ResourceCache
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OgEx.Supervisor)
  end

  # Emits a single startup warning when hostname allowlisting is disabled.
  defp warn_for_global_remote_access do
    config = Application.get_env(:og_ex, :remote_images, [])

    if Keyword.get(config, :enabled, false) and "*" in Keyword.get(config, :allowed_hosts, []) do
      require Logger

      Logger.warning("""
      OgEx remote image loading allows all external hosts. This increases the SSRF \
      attack surface. Prefer an explicit allowed_hosts list in production.
      """)
    end
  end

  # Announces the page-path canonicalization once per boot. Legacy signed URLs
  # remain verifiable this release; see OgEx.ConfigBuilder.verify/2.
  defp warn_for_trailing_slash_canonicalization do
    require Logger

    Logger.warning(
      "OgEx now signs image URLs with trimmed page paths (\"/path/\" -> \"/path\"). " <>
        "Trailing-slash URLs from older versions still work this release but are deprecated " <>
        "and will be removed in a future version."
    )
  end

  # The flags table backs once-per-node behaviors such as the legacy signature
  # warning. It is owned by the application master process and is recreated if
  # the application restarts, re-arming those gates.
  defp ensure_flags_table do
    if :ets.whereis(OgEx.Flags) == :undefined do
      :ets.new(OgEx.Flags, [:named_table, :public, :set])
    end

    :ok
  end
end
