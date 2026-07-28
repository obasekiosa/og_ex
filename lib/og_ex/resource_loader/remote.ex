defmodule OgEx.ResourceLoader.Remote do
  @moduledoc """
  Opt-in HTTP loader for images embedded in generated cards.

  Each request resolves and validates the destination before connecting. The
  request URL is rewritten to the selected address while TLS verification and
  the Host header retain the original hostname, preventing DNS rebinding.

  Remote loading is disabled by default and requires an explicit hostname
  allowlist. Redirect targets are subjected to the same scheme, hostname, DNS,
  and address checks. Direct external `og:image` values do not use this module
  because OgEx emits those URLs without fetching them.

  The README's embedded-external example shows the complete allowlist,
  controller, card HEEx, and generated output.
  """

  alias OgEx.Image.Source
  import Bitwise

  @default_max_bytes 5_000_000

  @doc """
  Loads an allowlisted remote source.

  `options` override the application `:remote_images` keyword configuration for
  this call. The function uses the configured resource cache, performs
  conditional revalidation when possible, and returns `{:ok, resource}` or a
  structured error.
  """
  def load(%Source{type: :remote, reference: url} = source, options \\ []) do
    config = Keyword.merge(Application.get_env(:og_ex, :remote_images, []), options)

    if Keyword.get(config, :enabled, false) do
      cache = Application.get_env(:og_ex, :resource_cache_module, OgEx.ResourceCache)

      case cache.fetch(url) do
        {:ok, resource} ->
          {:ok, resource}

        :error ->
          stale =
            case cache.fetch_stale(url) do
              {:ok, resource} -> resource
              :error -> nil
            end

          fetch(source, url, config, Keyword.get(config, :max_redirects, 2), cache, stale)
      end
    else
      {:error, :remote_images_disabled}
    end
  end

  # Validates one redirect hop, performs a pinned request, and caches only a
  # complete verified image response.
  defp fetch(source, url, config, redirects_left, cache, stale) do
    with {:ok, uri, address} <- validate_destination(url, config),
         {:ok, response} <- request(uri, address, config, stale) do
      handle_response(source, response, uri, config, redirects_left, cache, stale)
    end
  end

  # Handles success and redirect statuses without letting Req follow redirects
  # before OgEx has validated the new destination.
  defp handle_response(source, %{status: 200} = response, _uri, config, _left, cache, _stale) do
    body = response.body
    max_bytes = Keyword.get(config, :max_bytes, @default_max_bytes)

    with true <- is_binary(body) and byte_size(body) <= max_bytes,
         :ok <- supported_content_type(response),
         {:ok, resource} <- OgEx.ResourceLoader.Default.from_bytes(source, body) do
      resource = %{
        resource
        | etag: first_header(response, "etag"),
          last_modified: first_header(response, "last-modified")
      }

      ttl = Keyword.get(config, :cache_ttl, 300_000)
      :ok = cache.put(source.reference, resource, ttl)
      {:ok, resource}
    else
      false -> {:error, {:resource_too_large, max_bytes}}
      {:error, _reason} = error -> error
    end
  end

  defp handle_response(source, %{status: 304}, _uri, config, _left, cache, stale)
       when not is_nil(stale) do
    :ok = cache.put(source.reference, stale, Keyword.get(config, :cache_ttl, 300_000))
    {:ok, stale}
  end

  defp handle_response(source, %{status: status} = response, uri, config, left, cache, _stale)
       when status in 300..399 and left > 0 do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        next_url = uri |> URI.merge(location) |> URI.to_string()
        fetch(source, next_url, config, left - 1, cache, nil)

      [] ->
        {:error, {:resource_http_status, status}}
    end
  end

  defp handle_response(_source, %{status: status}, _uri, _config, _left, _cache, _stale),
    do: {:error, {:resource_http_status, status}}

  # Streams into the response struct and halts as soon as the byte limit is
  # crossed. The oversized partial body is never decoded or cached.
  defp request(uri, address, config, stale) do
    timeout = Keyword.get(config, :request_timeout, 8_000)
    task = Task.async(fn -> perform_request(uri, address, config, stale) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:resource_timeout, :request}}
    end
  end

  # Performs the pinned streaming request inside the total-timeout task.
  defp perform_request(uri, address, config, stale) do
    max_bytes = Keyword.get(config, :max_bytes, @default_max_bytes)
    pinned_url = pinned_url(uri, address)
    host_header = host_header(uri)

    into = fn {:data, chunk}, {request, response} ->
      body = response.body <> chunk
      response = %{response | body: body}
      action = if byte_size(body) > max_bytes, do: :halt, else: :cont
      {action, {request, response}}
    end

    Req.get(
      pinned_url,
      headers: [{"host", host_header} | validator_headers(stale)],
      redirect: false,
      retry: false,
      decode_body: false,
      into: into,
      connect_options: [
        timeout: Keyword.get(config, :connect_timeout, 2_000),
        hostname: uri.host
      ],
      receive_timeout: Keyword.get(config, :receive_timeout, 5_000)
    )
  rescue
    error -> {:error, {:resource_request_failed, Exception.message(error)}}
  end

  # Sends only standard HTTP cache validators retained for the same source.
  defp validator_headers(nil), do: []

  defp validator_headers(resource) do
    []
    |> maybe_header("if-none-match", resource.etag)
    |> maybe_header("if-modified-since", resource.last_modified)
  end

  # Adds a request header only when a non-empty validator exists.
  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  # Enforces scheme and host policy, then returns one validated, pinned address.
  defp validate_destination(url, config) do
    uri = URI.parse(url)

    with :ok <- allowed_scheme(uri.scheme, config),
         true <- is_binary(uri.host) and uri.host != "",
         :ok <- allowed_host(uri.host, Keyword.get(config, :allowed_hosts, [])),
         {:ok, addresses} <- resolve(uri.host),
         :ok <- validate_addresses(addresses) do
      {:ok, uri, hd(addresses)}
    else
      false -> {:error, {:invalid_remote_url, url}}
      {:error, _reason} = error -> error
    end
  end

  # HTTPS is the default; HTTP requires an explicit development-only option.
  defp allowed_scheme("https", _config), do: :ok

  defp allowed_scheme("http", config) do
    if Keyword.get(config, :allow_http, false), do: :ok, else: {:error, :http_not_allowed}
  end

  defp allowed_scheme(_scheme, _config), do: {:error, :unsupported_remote_scheme}

  # Matches exact hosts, subdomain wildcards, or the explicit global wildcard.
  defp allowed_host(host, patterns) do
    host = String.downcase(host)

    allowed? =
      Enum.any?(patterns, fn
        "*" -> true
        "*." <> suffix -> String.ends_with?(host, "." <> String.downcase(suffix))
        pattern -> host == String.downcase(pattern)
      end)

    if allowed?, do: :ok, else: {:error, {:resource_host_not_allowed, host}}
  end

  # Resolves literals without DNS and names through both address families.
  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, :einval} ->
        addresses =
          [:inet, :inet6]
          |> Enum.flat_map(fn family ->
            case :inet.getaddrs(charlist, family) do
              {:ok, values} -> values
              {:error, _reason} -> []
            end
          end)
          |> Enum.uniq()

        if addresses == [], do: {:error, {:resource_dns_failed, host}}, else: {:ok, addresses}
    end
  end

  # Rejects a hostname if any answer is unsafe, avoiding nondeterministic use of
  # a mixed public/private DNS response.
  defp validate_addresses(addresses) do
    case Enum.find(addresses, &unsafe_address?/1) do
      nil -> :ok
      address -> {:error, {:resource_unsafe_address, :inet.ntoa(address) |> to_string()}}
    end
  end

  # Covers IPv4 private, loopback, link-local, multicast, unspecified, and
  # reserved blocks including the cloud metadata range.
  defp unsafe_address?({a, b, _c, _d}) do
    a in [0, 10, 127] or
      a >= 224 or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b in [0, 168]) or
      (a == 192 and b == 88) or
      (a == 198 and b in [18, 19, 51]) or
      (a == 203 and b == 0)
  end

  # Rejects unspecified, loopback, unique-local, link-local, multicast, and
  # IPv4-mapped unsafe addresses.
  defp unsafe_address?({a, b, c, d, e, f, g, h}) do
    cond do
      {a, b, c, d, e, f, g, h} in [{0, 0, 0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 1}] ->
        true

      Bitwise.band(a, 0xFE00) == 0xFC00 ->
        true

      Bitwise.band(a, 0xFFC0) == 0xFE80 ->
        true

      Bitwise.band(a, 0xFF00) == 0xFF00 ->
        true

      {a, b, c, d, e, f} == {0, 0, 0, 0, 0, 0xFFFF} ->
        unsafe_address?({g >>> 8, g &&& 255, h >>> 8, h &&& 255})

      true ->
        false
    end
  end

  # Rewrites only the connection address. TLS hostname verification and Host
  # continue to use the original URI hostname.
  defp pinned_url(uri, address) do
    host =
      case tuple_size(address) do
        4 -> :inet.ntoa(address) |> to_string()
        8 -> :inet.ntoa(address) |> to_string()
      end

    %{uri | host: host} |> URI.to_string()
  end

  # Adds the non-default port to the HTTP Host header when needed.
  defp host_header(%{scheme: scheme, host: host, port: port})
       when (scheme == "https" and port in [nil, 443]) or (scheme == "http" and port in [nil, 80]),
       do: host

  defp host_header(%{host: host, port: port}), do: "#{host}:#{port}"

  # Requires a declared supported image media type in addition to byte-level
  # native verification.
  defp supported_content_type(response) do
    supported = ["image/png", "image/jpeg", "image/webp", "image/gif", "image/svg+xml"]

    case Req.Response.get_header(response, "content-type") do
      [value | _] ->
        type = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
        if type in supported, do: :ok, else: {:error, {:unsupported_image_type, type}}

      [] ->
        {:error, {:unsupported_image_type, nil}}
    end
  end

  # Returns the first response header value for resource revalidation.
  defp first_header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
