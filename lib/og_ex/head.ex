defmodule OgEx.Head do
  @moduledoc false

  import Plug.Conn

  @doc """
  Registers card configuration and metadata injection on a connection.

  Injection runs immediately before the completed response is sent.
  """
  def put_config(conn, config) do
    # register_before_send/2 runs after Phoenix has rendered the root layout,
    # which is the earliest point where a closing </head> is guaranteed to be
    # present in the response body.
    conn
    |> assign(:og_ex, config)
    |> register_before_send(&inject_metadata/1)
  end

  # Rewrites only complete binary HTML responses. Other body shapes and content
  # types are returned unchanged to avoid corrupting streams or files.
  defp inject_metadata(conn) do
    # Only complete, binary HTML bodies can be safely rewritten. Streaming,
    # file, JSON, and already-compressed responses are intentionally left alone.
    with [content_type | _] <- get_resp_header(conn, "content-type"),
         true <- String.starts_with?(content_type, "text/html"),
         body when is_binary(body) <- conn.resp_body,
         true <- String.contains?(String.downcase(body), "</head>") do
      tags = OgEx.Meta.to_html(conn.assigns.og_ex)
      updated_body = replace_closing_head(body, tags)

      conn
      # The previous content length described the body before metadata was
      # inserted. Let Plug recalculate it from the updated response.
      |> delete_resp_header("content-length")
      |> Map.put(:resp_body, updated_body)
    else
      _ -> conn
    end
  end

  # Inserts the pre-escaped metadata immediately before the first case-
  # insensitive closing head tag while slicing the original body bytes.
  defp replace_closing_head(body, tags) do
    case :binary.match(String.downcase(body), "</head>") do
      {position, _length} ->
        # Match against a lowercase copy but slice the original bytes so the
        # application's capitalization and formatting remain untouched.
        prefix = binary_part(body, 0, position)
        suffix = binary_part(body, position, byte_size(body) - position)
        prefix <> tags <> "\n" <> suffix

      :nomatch ->
        body
    end
  end
end
