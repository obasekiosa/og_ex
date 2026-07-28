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
end
