defmodule OgEx.ResourceCache do
  @moduledoc """
  Bounded in-memory cache for verified remote resources.

  Entries retain encoded bytes, fingerprints, and HTTP validators. Fresh
  entries are returned directly; stale entries are available only for
  conditional revalidation. The table is local to one BEAM node.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Starts the process that owns the resource ETS table.
  """
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc """
  Fetches a non-expired cached resource.

  Returns `{:ok, resource}` or `:error`, following `Map.fetch/2`.
  """
  def fetch(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, expires_at, resource, _size}] when expires_at > now ->
        {:ok, resource}

      [{^key, _expires_at, _resource, _size}] ->
        :error

      [] ->
        :error
    end
  end

  @doc """
  Returns a cached resource even after its freshness TTL has elapsed.

  The remote loader uses stale entries only to send conditional validators or
  to reuse bytes after a `304 Not Modified` response.
  """
  def fetch_stale(key) do
    case :ets.lookup(@table, key) do
      [{^key, _expires_at, resource, _size}] -> {:ok, resource}
      [] -> :error
    end
  end

  @doc """
  Stores a resource for `ttl` milliseconds while enforcing configured bounds.

  The default bounds are 128 entries and 25,000,000 bytes. When an insertion
  would exceed either bound, the current table is cleared first.
  """
  def put(key, resource, ttl) do
    GenServer.call(__MODULE__, {:put, key, resource, ttl})
  end

  @doc """
  Creates the private ETS table used by the cache.
  """
  @impl true
  def init(_options) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{bytes: 0}}
  end

  @doc """
  Inserts one cache entry and clears the cache before it can exceed its bounds.
  """
  @impl true
  def handle_call({:put, key, resource, ttl}, _from, state) do
    config = Application.get_env(:og_ex, :resource_cache, [])
    max_entries = Keyword.get(config, :max_entries, 128)
    max_bytes = Keyword.get(config, :max_bytes, 25_000_000)
    size = byte_size(resource.bytes)

    previous_size =
      case :ets.lookup(@table, key) do
        [{^key, _expires_at, _resource, old_size}] -> old_size
        [] -> 0
      end

    projected_bytes = state.bytes - previous_size + size
    adding_entry? = previous_size == 0

    state =
      if (adding_entry? and :ets.info(@table, :size) >= max_entries) or
           projected_bytes > max_bytes do
        :ets.delete_all_objects(@table)
        %{bytes: 0}
      else
        %{state | bytes: state.bytes - previous_size}
      end

    if size <= max_bytes do
      :ets.insert(@table, {key, System.monotonic_time(:millisecond) + ttl, resource, size})
      {:reply, :ok, %{state | bytes: state.bytes + size}}
    else
      {:reply, :ok, state}
    end
  end
end
