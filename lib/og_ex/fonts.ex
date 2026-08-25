defmodule OgEx.Fonts do
  @moduledoc false

  # Accepted configuration entry shapes. Binaries keep their historical dual
  # semantics: an existing file is read as font bytes, any other binary is
  # passed through as already-loaded bytes. The `{:ogex_font, path}` marker is
  # the only shape that unambiguously means "path", which is what makes its
  # missing-file errors actionable. It is also plain data with no module
  # dependency, so it stays safe to evaluate from config.exs before OgEx is
  # compiled.
  @type entry ::
          binary()
          | {:ogex_font, binary()}
          | {module(), atom(), [term()]}
          | (-> term())

  @doc """
  Builds a lazy font entry for a file below the configured `:otp_app`.

  Returns the `{:ogex_font, path}` tuple; nothing is read from the filesystem
  and no application is consulted until fonts load during a render:

      config :og_ex,
        otp_app: :my_app,
        fonts: [OgEx.font("priv/fonts/Inter-Regular.ttf")]

  Relative paths resolve with `Application.app_dir/2` at load time. Absolute
  paths pass through unchanged.

  Configuration evaluated before OgEx is compiled cannot call this function.
  In `config.exs` use the equivalent literal tuple instead:

      fonts: [{:ogex_font, "priv/fonts/Inter-Regular.ttf"}]
  """
  def font(path) when is_binary(path), do: {:ogex_font, path}

  @doc """
  Loads every configured font, resolving lazy entries at call time.

  Returns `{:ok, binaries}` or
  `{:error, {:invalid_font_config, message}}`. Plain binary entries keep
  their historical behavior: existing files are read, other binaries are
  treated as font bytes. Lazy entries (`OgEx.font/1` markers, MFAs, and
  zero-arity funs) are invoked here, so configuration never touches the
  filesystem during compilation or release assembly.
  """
  def load do
    :og_ex
    |> Application.get_env(:fonts, [])
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case resolve(entry) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bytes_list} -> {:ok, Enum.reverse(bytes_list)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Validates configuration entry shapes without touching the filesystem.

  Intended for application boot. Invalid entries are reported with a warning
  listing the accepted forms; existence is deliberately not checked because
  font files may legitimately appear only inside the assembled release.
  """
  def validate_config do
    invalid =
      :og_ex
      |> Application.get_env(:fonts, [])
      |> Enum.reject(&valid_shape?/1)

    if invalid != [] do
      require Logger

      Logger.warning(
        "OgEx font configuration contains invalid entries: " <>
          "#{inspect(invalid, limit: 5)}. Accepted entries are a font path or " <>
          "font-bytes binary, an OgEx.font/1 marker, {mod, fun, args}, or a " <>
          "zero-arity fun returning either."
      )
    end

    :ok
  end

  # Logs an actionable configuration error once per node and message. Repeats
  # would spam every cache miss while the misconfiguration persists; telemetry
  # still carries each failure.
  def log_error_once(message) do
    gate_key = {__MODULE__, :config_error, message}
    fast_key = {__MODULE__, :config_error_logged, message}

    unless :persistent_term.get(fast_key, false) do
      claimed =
        try do
          :ets.insert_new(OgEx.Flags, {gate_key, true})
        rescue
          ArgumentError -> true
        end

      if claimed do
        :persistent_term.put(fast_key, true)

        require Logger
        Logger.error(message)
      end
    end

    :ok
  end

  defp resolve(binary) when is_binary(binary) do
    if File.regular?(binary) do
      {:ok, File.read!(binary)}
    else
      # Not a readable file: historical behavior treats the binary as
      # already-loaded font bytes and lets the native decoder judge it.
      {:ok, binary}
    end
  end

  defp resolve({:ogex_font, path}) when is_binary(path) do
    if Path.type(path) == :absolute do
      read_marker_file(path, path)
    else
      case otp_app() do
        {:ok, app} ->
          read_marker_file(Application.app_dir(app, path), path)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve({mod, fun, args} = mfa) when is_atom(mod) and is_atom(fun) and is_list(args) do
    resolve_lazy(fn -> apply(mod, fun, args) end, inspect(mfa, limit: 3))
  end

  defp resolve(fun) when is_function(fun, 0) do
    resolve_lazy(fun, "zero-arity fun")
  end

  defp resolve(other) do
    {:error,
     invalid_config_message(
       "font entries must be a font path or font-bytes binary, an OgEx.font/1 marker, " <>
         "{mod, fun, args}, or a zero-arity fun; got: #{inspect(other)}"
     )}
  end

  defp read_marker_file(resolved, configured) do
    if File.regular?(resolved) do
      {:ok, File.read!(resolved)}
    else
      {:error,
       invalid_config_message(
         "OgEx.font(#{inspect(configured)}) resolved to #{resolved}, which does not exist. " <>
           "Resolve font paths at runtime with Application.app_dir/2 or OgEx.font/1, and " <>
           "make sure the file ships inside the release."
       )}
    end
  end

  defp resolve_lazy(resolver, kind) do
    resolved =
      try do
        {:ok, resolver.()}
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end

    case resolved do
      {:ok, binary} when is_binary(binary) ->
        resolve(binary)

      {:ok, other} ->
        {:error,
         invalid_config_message(
           "#{kind} returned #{inspect(other)}; font entries must resolve to a path or font bytes"
         )}

      {:error, failure} ->
        {:error, invalid_config_message("#{kind} failed while resolving a font: #{failure}")}
    end
  end

  defp otp_app do
    case Application.get_env(:og_ex, :otp_app) do
      nil ->
        {:error,
         invalid_config_message(
           "OgEx.font/1 requires config :og_ex, :otp_app to resolve relative paths"
         )}

      app when is_atom(app) ->
        {:ok, app}

      other ->
        {:error,
         invalid_config_message("config :og_ex, :otp_app must be an atom; got: #{inspect(other)}")}
    end
  end

  defp invalid_config_message(message) do
    {:invalid_font_config, "OgEx font configuration error: " <> message}
  end

  defp valid_shape?(binary) when is_binary(binary), do: true
  defp valid_shape?({:ogex_font, path}) when is_binary(path), do: true

  defp valid_shape?({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args),
    do: true

  defp valid_shape?(fun) when is_function(fun, 0), do: true
  defp valid_shape?(_other), do: false
end
