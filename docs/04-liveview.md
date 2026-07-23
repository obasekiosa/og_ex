# Approach 4: LiveView Integration

LiveView requires a slightly different integration because there is no
controller `conn` after the initial disconnected render. Metadata must live in
socket assigns, while the generated image must still be available through an
ordinary HTTP request that social crawlers can fetch.

## Proposed LiveView API

```elixir
def mount(%{"id" => id}, _session, socket) do
  post = Blog.get_post!(id)

  socket =
    socket
    |> assign(:post, post)
    |> og(
      title: post.title,
      description: post.summary,
      card: {MyAppWeb.PostCard, post: post},
      image_path: ~p"/og/posts/#{post}"
    )

  {:ok, socket}
end
```

For parameter-driven pages:

```elixir
def handle_params(%{"id" => id}, _uri, socket) do
  post = Blog.get_post!(id)

  {:noreply,
   socket
   |> assign(:post, post)
   |> og(
     title: post.title,
     description: post.summary,
     card: {MyAppWeb.PostCard, post: post},
     image_path: ~p"/og/posts/#{post}"
   )}
end
```

## Layout integration

```heex
<head>
  <OgEx.meta config={assigns[:og_ex]} />
</head>
```

For live navigation, a hook can update the browser DOM:

```heex
<OgEx.live_meta config={assigns[:og_ex]} />
```

However, social crawlers primarily inspect the initial server-rendered HTML and
usually do not execute the LiveView WebSocket lifecycle. The disconnected
initial render must contain the correct tags.

## Image endpoint strategies

### Explicit generated route

The robust design is one library-owned controller:

```elixir
scope "/og", MyAppWeb do
  pipe_through :browser
  og_ex "/posts/:id", MyAppWeb.PostCard,
    loader: {Blog, :get_post!}
end
```

The LiveView only supplies the resulting image URL. This is reliable but is not
fully automatic.

### Registry-based declaration

A route-level macro can declare both the LiveView and its card loader:

```elixir
live_with_og "/posts/:id",
  MyAppWeb.PostLive.Show,
  card: MyAppWeb.PostCard,
  load: {Blog, :get_post!}
```

The macro generates both:

```text
/posts/:id
/posts/:id/__og__.png
```

This is more automatic but couples the package tightly to Phoenix router
internals.

### Query parameter on the LiveView route

```text
/posts/42?__og_image=v1
```

This appears simplest but LiveView routing is not designed to return arbitrary
PNG responses from `mount/3`. An endpoint plug would need to intercept the
request before the LiveView plug and independently load the card data. That
means the LiveView's `mount/3` cannot be the sole image implementation.

## Live metadata changes

Live navigation may change `<meta>` tags in the user's browser, but links shared
to crawlers must have stable, directly requestable URLs. A client-side metadata
change alone is insufficient.

For canonical shareable states, prefer paths:

```text
/posts/42
/posts/43
```

over transient socket-only state:

```text
/posts/42  # card depends on an unencoded tab selected in the socket
```

Any state affecting the card should be recoverable from path/query parameters
or persistent storage.

## Advantages

- Metadata is declared next to LiveView data loading.
- Named card components can be shared with controller pages.
- Initial HTML and subsequent live navigation can use the same configuration.

## Drawbacks

- The image still needs a normal HTTP rendering pipeline.
- Socket-only assigns cannot be recovered by a crawler.
- Updating DOM metadata during live navigation needs a hook or supported head
  patching mechanism.
- Automatic same-path image handling is substantially harder than controllers.

## Requirements

- `OgEx.LiveView.og/2` operating on sockets.
- Initial-layout metadata rendering.
- A conventional image controller, generated route, or pre-LiveView endpoint
  plug.
- A loader contract that reconstructs card assigns from request parameters.
- Optional client hook for live metadata replacement.

## Recommendation

Use the same reusable card modules as controllers, but give LiveView a generated
or explicitly declared image route. Do not depend on executing the LiveView
process to serve crawler images.
