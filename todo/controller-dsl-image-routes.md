# Controller DSL and image-route plan

## Goal

Allow a Phoenix controller to declare the social card associated with an
action, provide a small loader dedicated to that card, and choose whether OgEx
emits a dedicated path URL or a query-based image URL.

The declaration should be the only card-specific wiring:

```elixir
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller
  use OgEx.Controller

  og_card :show, MyAppWeb.PostOgCard,
    image_route: :path

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end
```

The normal page request must continue to run `show/2`. An image request must
run `PostOgCard.load/2` and the card renderer without running `show/2`.
Applications can override the card-local loader in the declaration when a route
needs different loading or authorization.

## Design principles

- Keep card appearance in HEEx and CSS inside an `OgEx.Card` module.
- Keep page loading and image loading independent.
- Do not require an application-owned image controller or one route per card.
- Make the URL strategy an explicit application or declaration choice.
- Preserve the existing query-based behavior during migration.
- Do not place serialized card assigns in a signed URL.
- Keep signed tokens short, opaque, scoped, and lazily generated.
- Treat image loaders as public-data boundaries because social crawlers normally
  do not carry the original browser session.
- Detect invalid declarations and route conflicts as early as Phoenix permits.
- Keep Open Graph and Twitter image roles separate even when they share a card.

## Proposed public API

### Basic declaration

```elixir
og_card :show, MyAppWeb.PostOgCard
```

This associates `PostController.show/2` with `PostOgCard`.

The default loader belongs to the card itself:

```elixir
defmodule MyAppWeb.PostOgCard do
  use OgEx.Card, width: 1200, height: 630

  @impl OgEx.Card
  def load(_conn, %{"id" => id}) do
    case Blog.get_public_post(id) do
      nil ->
        {:error, :not_found}

      post ->
        {:ok,
         %{
           title: post.title,
           description: post.summary
         }}
    end
  end

  @impl OgEx.Card
  def render(assigns) do
    ~H"""
    <main>
      <h1>{@title}</h1>
      <p>{@description}</p>
    </main>
    """
  end
end
```

This keeps the normal case close to the intended experience: the controller
declares the card, while the card defines how its image data is loaded and how
the result looks.

A card reused by several routes can inspect the originating controller and
action through stable OgEx helpers:

```elixir
@impl OgEx.Card
def load(conn, params) do
  case {OgEx.controller(conn), OgEx.action(conn)} do
    {MyAppWeb.PostController, :show} ->
      load_post(params)

    {MyAppWeb.ArticleController, :show} ->
      load_article(params)

    {MyAppWeb.HomeController, :index} ->
      {:ok, %{title: "Home"}}
  end
end
```

Users should not match directly on `conn.private.phoenix_action` or
`conn.private.phoenix_controller`. In query mode those fields may describe the
original page route, but in path mode Phoenix initially dispatches to an
internal OgEx route. OgEx must carry the originating controller and action
through verification and expose them through its documented helpers.

An explicit controller loader is the escape hatch for a card that is purely
presentational, is reused across unrelated resources, or requires
controller-specific authorization:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  load: &load_post_card/2
```

Loader resolution order:

1. an explicit `load:` option on the `og_card` declaration;
2. `load/2` implemented by the card module;
3. a clear compile-time error when neither exists.

OgEx should not infer conventional controller function names. Explicit
overrides are easier to find, validate, and refactor.

### Choose the URL strategy

Path mode:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  load: &load_post_card/2,
  image_route: :path
```

Query mode:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  load: &load_post_card/2,
  image_route: :query
```

Structured options:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  image_route:
    {:path,
     og: "opengraph-image",
     twitter: "twitter-image"}
```

```elixir
og_card :show, MyAppWeb.PostOgCard,
  image_route: {:query, param: "__og_ex"}
```

### Global default

```elixir
# config/config.exs
config :og_ex,
  image_route: :path
```

Resolution order:

1. `image_route:` on the `og_card` declaration;
2. `config :og_ex, :image_route`;
3. the OgEx default, `:path`.

The global setting should accept the same structured values as a declaration:

```elixir
config :og_ex,
  image_route:
    {:path,
     og: "opengraph-image",
     twitter: "twitter-image"}
```

### Separate Open Graph and Twitter cards

The declaration should permit one card for both roles or a different Twitter
card:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  twitter: MyAppWeb.PostTwitterCard,
  load: &load_post_card/2
```

When the declaration supplies `load:`, both cards receive that loader's result
by default. A separate loader can be introduced only if real applications
demonstrate a need:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  twitter: [
    card: MyAppWeb.PostTwitterCard,
    load: &load_post_twitter_card/2
  ],
  load: &load_post_card/2
```

The first release should prefer one loader to avoid unnecessary API surface.
When there is no explicit declaration loader, each selected card owns its
`load/2` callback. OgEx should avoid calling two loaders if the Open Graph and
Twitter roles use the same card and normalized request identity.

### Disable a card conditionally

The loader may return `:skip` when the action should render HTML without social
image metadata:

```elixir
defp load_post_card(_conn, %{"id" => id}) do
  case Blog.get_public_post(id) do
    %{shareable?: true} = post ->
      {:ok, %{title: post.title}}

    _post ->
      :skip
  end
end
```

This needs careful lifecycle handling because the HTML response needs to know
whether metadata should be emitted. The initial implementation may omit
conditional skipping if supporting it would require running the image loader
on the HTML request. A declaration-level condition based on existing assigns is
safer:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  when: & &1.assigns.post.shareable?
```

The first implementation should not promise either form until the lifecycle is
settled and tested.

## Loader contract

### Card-local loading is the default

`OgEx.Card` should define `load/2` as an optional callback:

```elixir
@callback load(Plug.Conn.t(), map()) :: loader_result()
@optional_callbacks load: 2
```

The callback runs only for an image request. It must not run merely because the
normal HTML page renders social metadata.

Keeping loading in the card has important advantages:

- the basic controller declaration has no additional wiring;
- data selection, metadata, versioning, HEEx, and CSS can be understood from one
  module;
- a card owns the shape of the assigns consumed by its template;
- changing the card's data requirements does not require editing the
  controller;
- simple cards are easier to copy, test end to end, and reuse;
- the API remains close to the component-like experience OgEx is intended to
  provide.

It also has costs:

- the card becomes coupled to application contexts and persistence;
- a shared visual card may accumulate controller/action branching;
- data loading and presentation become two responsibilities in one module;
- complete card tests may need database fixtures or context mocks;
- authorization rules can become harder to audit when many routes share a card;
- matching on controller modules couples the card to routing structure.

The render callback remains independently testable with a plain assigns map
even when the same module implements `load/2`.

Explicit declaration loaders address the complex cases without making them the
default. A reusable presentation card can omit `load/2`, while each controller
provides the correct data boundary:

```elixir
og_card :show, MyAppWeb.SharedOgCard,
  load: &load_post_card/2
```

The explicit loader must override a card-local loader when both are present.

### Types

The public contract should be documented approximately as:

```elixir
@type loader_assigns :: map()

@type loader_error ::
        :not_found
        | :forbidden
        | :unavailable
        | term()

@type loader_result ::
        {:ok, loader_assigns()}
        | {:error, loader_error()}

@callback load(Plug.Conn.t(), map()) :: loader_result()
```

The function receives:

- the current image-request connection enriched with trusted OgEx origin
  information;
- the path and query parameters reconstructed by Phoenix for the image request.

Stable accessors should include:

```elixir
OgEx.controller(conn)
OgEx.action(conn)
OgEx.route_params(conn)
OgEx.image_role(conn)
```

The first two accessors return the controller and action that declared the card,
not the internal handler used to serve a path-mode request. `route_params/1`
returns the normalized parameters permitted by the declaration. `image_role/1`
returns `:open_graph` or `:twitter`.

The callback should receive `params` directly for ordinary pattern matching:

```elixir
def load(conn, %{"id" => id, "locale" => locale}) do
  case OgEx.action(conn) do
    :show -> load_show(id, locale)
    :preview -> load_preview(id, locale)
  end
end
```

The implementation spike should compare these accessors with an explicit
`OgEx.Request` context struct. A context struct may make the origin semantics
clearer:

```elixir
%OgEx.Request{
  conn: conn,
  controller: MyAppWeb.PostController,
  action: :show,
  params: %{"id" => "42"},
  path_params: %{"id" => "42"},
  query_params: %{},
  role: :open_graph
}
```

Do not expose raw `conn.private` keys as the public contract. If the context
struct is selected, the final callback should become `load/1`; OgEx should not
support two equivalent callback shapes indefinitely.

It returns:

- `{:ok, assigns}` to render the card;
- `{:error, :not_found}` when the underlying public resource does not exist;
- `{:error, :forbidden}` when the resource must not be exposed;
- `{:error, reason}` for a temporary or internal loading failure.

The loader result becomes the assigns passed to:

- the card's `metadata/1`;
- the card's `version/1`;
- the card's `render/1`.

OgEx should reject a successful loader result that is not a map.

### Explicit loader visibility

Explicit captures of private local functions should work:

```elixir
load: &load_post_card/2
```

The macro can store the local function name and arity in declaration metadata
instead of attempting to persist an anonymous function at runtime. Generated
dispatch code inside the controller can call the private function legally.

Remote module-function tuples may be useful for shared loaders:

```elixir
load: {MyAppWeb.OgLoaders, :post}
```

This form can be added in the initial implementation if it does not complicate
compile-time validation:

```elixir
def post(conn, params), do: {:ok, %{...}}
```

### Authentication and authorization

Social crawler requests usually have no application session or authenticated
browser identity. Loaders must not assume that:

- `conn.assigns.current_user` exists;
- session cookies from the original HTML request will be sent;
- browser-only authorization can be repeated safely.

The signed token authorizes only the declared public card operation. It must not
turn a private page into a public data endpoint.

Documentation should recommend:

- loading only intentionally public fields;
- querying through an application function designed for public card data;
- returning `{:error, :not_found}` for non-public records to avoid revealing
  whether private records exist;
- excluding secrets and full database structs from loader assigns;
- never placing private assigns inside the signed token.

### Exceptions and exits

OgEx should execute the loader inside a controlled boundary:

- a normal error tuple becomes a defined image response;
- an exception is logged with sanitized declaration identity;
- exits and throws are converted into a structured internal error;
- the response is non-cacheable;
- no exception from the image loader can affect the HTML request because the
  requests are independent.

If request coalescing is implemented later, loader execution and rendering need
separate consideration. The loader may be request-specific and should not be
coalesced before a stable card cache key is known.

## URL strategies

### Path mode

Default URLs:

```text
Page:
GET /posts/42

Open Graph image:
GET /posts/42/opengraph-image/SIGNED_TOKEN

Twitter image:
GET /posts/42/twitter-image/SIGNED_TOKEN
```

Requirements:

- preserve all dynamic and scoped route segments;
- preserve endpoint URL prefixes;
- generate absolute URLs through the endpoint configuration;
- percent-encode path components correctly;
- use different signed identities for Open Graph and Twitter roles;
- prevent a token generated for one action from being replayed against another;
- prevent a token generated for one canonical page path from being replayed
  against another;
- reject suffix conflicts with application routes;
- keep the token opaque and avoid leaking loader assigns;
- decide whether an optional format extension improves compatibility:

```text
/posts/42/opengraph-image/SIGNED_TOKEN.png
/posts/42/opengraph-image/SIGNED_TOKEN.svg
```

The media type remains authoritative even if an extension is added. A token
must bind the selected format so changing an extension cannot change the
response type.

### Query mode

Default URLs:

```text
Page:
GET /posts/42

Open Graph image:
GET /posts/42?__og_ex=SIGNED_TOKEN

Twitter image:
GET /posts/42?__og_ex=SIGNED_TOKEN
```

Requirements:

- intercept the image request before Phoenix dispatches the declared action;
- remove the internal OgEx parameter before supplying application query
  parameters to the loader;
- preserve application query parameters that are part of the card identity;
- exclude common tracking parameters unless the application explicitly opts
  into them;
- reject duplicate internal parameters;
- allow a configurable parameter name;
- warn or fail when the configured parameter conflicts with an application
  parameter declared as meaningful;
- bind the token to the canonical route, controller, action, card, role, format,
  dimensions, and content version.

Example with an application parameter:

```text
/posts/42?locale=en&__og_ex=SIGNED_TOKEN
```

OgEx needs a policy for which query parameters affect signing and loading:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  image_route: :query,
  params: [:locale]
```

The initial implementation should include path parameters automatically and
require an explicit allowlist for query parameters. This avoids signing
tracking parameters such as `utm_source`.

### URL strategy comparison

| Concern | Path mode | Query mode |
| --- | --- | --- |
| Page action skipped | Yes | Yes, through early interception |
| New Phoenix route shape | Yes | No |
| Human-readable image URL | Better | Less clear |
| Compatibility with current OgEx | Migration required | Closest match |
| Route conflicts | Suffix can conflict | Parameter can conflict |
| CDN cache keys | Usually straightforward | CDN must include query string |
| Router integration | Required | Controller integration may be sufficient |

## Phoenix integration

### Controller integration

`use OgEx.Controller` should:

- import `og_card/2` and `og_card/3`;
- accumulate declaration metadata at compile time;
- validate duplicate action declarations;
- validate local loader names and arities when possible;
- generate a private dispatch function that selects an explicit declaration
  loader or delegates to the card's `load/2`;
- install an early controller plug for query-mode image requests;
- expose declarations to the router integration and runtime registry without
  serializing anonymous functions.

Potential generated functions:

```elixir
def __og_ex_cards__ do
  %{show: %{card: MyAppWeb.PostOgCard, loader: :card}}
end

def __og_ex_load__(:show, conn, params) do
  MyAppWeb.PostOgCard.load(conn, params)
end
```

These names are internal and should be versioned or treated as private.

### Router constraint

A controller macro cannot reliably add routes to a Phoenix router that has
already been compiled. Path mode therefore requires a single application-wide
router integration.

Proposed API:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use OgEx.Router

  # Existing pipelines and routes remain unchanged.
end
```

`use OgEx.Router` should install one internal handler capable of recognizing
signed OgEx path requests. It must not require one route declaration per
controller action.

An alternative explicit macro may be clearer about route ordering:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import OgEx.Router

  # Application routes...

  og_ex_routes()
end
```

This is more honest about where a catch-all or suffix route is inserted and
makes conflicts easier to reason about. The implementation spike should compare
both APIs before the public contract is finalized.

### Route ordering

The path handler must not shadow application routes.

Questions to resolve with a prototype:

- Can Phoenix express the handler as a suffix pattern without a broad catch-all?
- Does it need to appear after application routes?
- Can scoped routes and host constraints be preserved?
- How does it behave under `scope "/admin", MyAppWeb.Admin`?
- Can route metadata identify the original controller and action without
  duplicating the application's route table?

If a universal suffix handler cannot preserve Phoenix routing semantics safely,
OgEx should generate image URLs under a reserved top-level prefix:

```text
/_og_ex/posts/42/opengraph-image/SIGNED_TOKEN
```

This is less attractive but substantially easier to route without conflicts.
The public API should not promise same-path suffix URLs until the routing spike
proves them reliable.

### Endpoint integration

The current endpoint integration should remain available during migration.

The target architecture is:

- query requests intercepted by the controller plug before action dispatch;
- path requests handled through `OgEx.Router`;
- signing performed lazily only when head metadata is rendered;
- no general endpoint plug required for new applications unless Phoenix routing
  constraints make it unavoidable.

Removing endpoint integration is a compatibility decision and should not happen
in the same release that introduces the new DSL unless a deprecation path is
documented.

## Declaration registry

Path requests need to resolve a signed declaration identity to:

- controller module;
- controller action;
- card module;
- loader dispatch;
- image role;
- route strategy;
- dimensions and format.

Possible approaches:

### Compile-time module dispatch

Put controller and action identity in the signed token, then call:

```elixir
controller.__og_ex_load__(action, conn, params)
```

Advantages:

- no process or ETS registry;
- deterministic across releases;
- works naturally in releases and multiple nodes.

Risks:

- module names make tokens longer unless represented by a compact signed ID;
- renamed modules invalidate outstanding URLs;
- untrusted module names must never be converted to atoms.

### Runtime registry

Register declarations during application startup and encode a compact integer or
digest in the token.

Advantages:

- shorter tokens;
- easy lookup.

Risks:

- startup ordering;
- consistency across rolling deployments and nodes;
- unstable numeric identifiers if compilation order changes;
- missing registration produces runtime failures.

### Recommended hybrid

Generate a stable declaration ID at compile time:

```elixir
:crypto.hash(
  :sha256,
  "#{controller}:#{action}:#{card}:#{role}"
)
|> binary_part(0, 12)
```

Each controller exposes its declarations, and an application-level registry maps
stable IDs to module dispatch targets. The token carries the compact ID, not a
module name or assigns.

Collision detection must occur when declarations are registered. The digest
length should be selected based on a documented collision analysis rather than
the illustrative 12-byte value above.

## Signed token

### What it should contain

The token should contain only the minimum data needed to validate and dispatch
the image request:

- token format version;
- compact declaration ID;
- image role;
- compact content-version fingerprint;
- expiry or issuance bucket if expiration is enabled.

Information already present in the request or declaration registry should not be
duplicated in the token.

### What it must bind

The signature must bind:

- canonical page path;
- selected path/query parameters;
- controller action declaration;
- card module identity through the declaration ID;
- Open Graph or Twitter role;
- dimensions;
- output format;
- application-provided card version.

The dimensions and format may be obtained from the declaration during
verification rather than stored in the visible payload, as long as they are
included in the signed material.

### Lazy generation

Declaring a card must not sign a token immediately.

The token should be generated only when the layout or head component asks OgEx
for social metadata. This preserves the existing lazy-signing direction and
avoids work for responses that never render an HTML head.

Within one response, OgEx should memoize the generated metadata in `conn.assigns`
or equivalent render state so repeated head component calls do not sign twice.

### Expiration

Long-lived social image URLs are useful because crawlers and caches revisit
them. The default token should not use a short session-style expiry.

Options:

- no time expiry; content version changes produce a new URL;
- configurable long expiry;
- key rotation invalidates old signatures operationally.

The first implementation should favor version-based invalidation and document
the effect of signing-key rotation.

## Request lifecycles

### HTML request

For `GET /posts/42`:

1. Phoenix matches `PostController.show/2`.
2. The normal controller action loads page data.
3. The action renders its template.
4. The layout asks OgEx for head metadata.
5. OgEx finds the `:show` declaration.
6. OgEx obtains metadata and version information available from the HTML
   assigns without executing the image loader.
7. OgEx lazily creates the signed Open Graph and optional Twitter URLs.
8. OgEx injects `og:*` and `twitter:*` tags.
9. Phoenix returns the HTML response.

This lifecycle exposes a design requirement: the HTML request needs enough
metadata to produce title, description, alt text, and a content version without
executing the image loader.

Possible sources, in priority order:

1. normal render assigns passed to `card.metadata/1` and `card.version/1`;
2. explicit metadata supplied by the controller render call;
3. a lightweight declaration callback that runs only when metadata is needed.

The API must not silently run an expensive image loader during every HTML
request.

### Path image request

For `GET /posts/42/opengraph-image/SIGNED_TOKEN`:

1. `OgEx.Router` recognizes the reserved image path.
2. OgEx verifies the signature and canonical page path.
3. OgEx resolves the declaration ID without creating atoms from request data.
4. OgEx reconstructs allowed path and query parameters.
5. OgEx calls the declared loader.
6. The loader returns card assigns.
7. OgEx calls card metadata/version/render functions as required.
8. OgEx checks the generated-image cache.
9. OgEx renders through Takumi on a cache miss.
10. OgEx returns the image with the correct media type and cache headers.

The normal controller action is never invoked.

### Query image request

For `GET /posts/42?__og_ex=SIGNED_TOKEN`:

1. Phoenix matches `PostController.show/2`.
2. The early OgEx controller plug sees the internal query parameter.
3. OgEx verifies the signature before action dispatch.
4. OgEx removes the internal parameter from application-visible parameters.
5. OgEx calls the declaration loader.
6. OgEx checks the cache and renders if required.
7. OgEx halts the connection with the image response.

`show/2` is never invoked.

### Cache identity

The generated-image cache key should include:

- stable declaration ID;
- role;
- normalized allowed parameters;
- card dimensions and format;
- `card.version(assigns)`;
- renderer version;
- resolved embedded-resource fingerprints.

The signed URL does not need to contain the full cache key.

## Metadata and loader separation

The card loader exists to avoid page-only work during image requests, but the
HTML response still needs social metadata.

Recommended initial rule:

- HTML metadata comes from the normal action's render assigns;
- image rendering assigns come from the loader;
- both assign maps must provide the fields used by `metadata/1` and `version/1`.

Example:

```elixir
def show(conn, %{"id" => id}) do
  post = Blog.get_post!(id)

  render(conn, :show,
    post: post,
    title: post.title,
    description: post.summary
  )
end

defp load_post_card(_conn, %{"id" => id}) do
  post = Blog.get_public_post_for_og!(id)

  {:ok,
   %{
     title: post.title,
     description: post.summary
   }}
end
```

This duplicates selection of a few card fields but keeps the two request paths
honest and independently optimizable.

A later convenience API could derive a compact metadata snapshot during the
HTML request and register it in a shared cache. That must remain an optimization,
not the only source of truth, because social crawlers may request an image URL
after a deployment or cache eviction.

## Error handling

### Loader results

Recommended response mapping:

| Loader result | Image response | Cache policy |
| --- | --- | --- |
| `{:ok, assigns}` | Rendered image | Normal successful policy |
| `{:error, :not_found}` | `404` | Short public cache or `no-store`, configurable |
| `{:error, :forbidden}` | `404` | `no-store` |
| `{:error, :unavailable}` | `503` | `no-store` |
| `{:error, reason}` | `503` | `no-store` |
| Exception, exit, or throw | `503` | `no-store` |

Returning `404` for forbidden cards avoids confirming the existence of private
resources.

### Invalid requests

- missing token: allow the normal page request in query mode;
- malformed token: `404`;
- invalid signature: `404`;
- declaration not present in the deployed release: `404`;
- path or parameter mismatch: `404`;
- expired token, if expiration is enabled: `404`;
- unsupported role or format: `404`.

Signature errors should not disclose whether the route, controller, record, or
card exists.

### Fallback images

Fallback behavior should use the policy designed in `todo/image_plan.md`.

The controller DSL may eventually accept:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  load: &load_post_card/2,
  fallback: "/images/default-og.png"
```

Fallback support should be implemented after the base loader and route lifecycle
works. It needs:

- verified local public or private fallback sources;
- a recursion guard;
- distinct telemetry;
- bounded caching;
- a clear rule for which loader and renderer failures are eligible.

## Telemetry

Add events around declaration dispatch and loading:

```elixir
[:og_ex, :loader, :start]
[:og_ex, :loader, :stop]
[:og_ex, :loader, :exception]

[:og_ex, :route, :verify, :stop]
```

Measurements:

- loader duration;
- verification duration;
- optionally queue and rendering duration through existing image events.

Metadata:

- declaration ID;
- controller and action from trusted registry data;
- role;
- route strategy;
- success or sanitized failure class;
- cache status when relevant.

Never emit:

- signed tokens;
- complete query strings;
- loader assigns;
- private record identifiers unless the application explicitly adds them;
- external resource credentials.

## Compile-time validation

The DSL should fail compilation for:

- an action declared more than once;
- a card module that does not implement the expected behaviour;
- an invalid loader capture or arity when it can be determined;
- an unsupported `image_route` value;
- empty or unsafe path suffixes;
- invalid query parameter names;
- identical Open Graph and Twitter suffixes when roles require distinct URLs;
- options that are meaningful only for the other route strategy;
- unknown DSL options.

Warnings may be more appropriate for:

- a card-local loader that cannot be verified until the card module finishes
  compiling;
- wildcard query parameter inclusion;
- legacy endpoint and new router integrations enabled simultaneously;
- route configuration that falls back to the reserved top-level prefix.

Error messages should include the controller, action, offending option, and a
valid example.

## Compatibility and migration

### Existing controller usage

Current applications should continue to work while the DSL is introduced:

```elixir
render(conn, :show, og: MyAppWeb.PostOgCard)
```

The new declaration form:

```elixir
og_card :show, MyAppWeb.PostOgCard,
  load: &load_post_card/2
```

should be opt-in for the first release.

### Existing query URLs

Existing signed query URLs should remain verifiable for a documented transition
period. Introduce a token version byte so OgEx can distinguish:

- legacy assign-bearing or earlier query tokens;
- new declaration-based tokens.

Do not keep compatibility code indefinitely without a removal version.

### Deprecation sequence

1. Add the DSL, loader, and both route strategies.
2. Document existing render-time selection as legacy but supported.
3. Gather feedback from applications using scoped and complex routes.
4. Deprecate old endpoint interception only after path and query replacements
   are proven.
5. Remove legacy behavior in a separately announced release.

Because OgEx is still pre-1.0, this can happen across minor releases, but release
notes must state the migration consequences clearly.

## Testing plan

### DSL compilation

- a controller can declare one card;
- a controller can declare multiple actions and cards;
- a card-local `load/2` is selected when `load:` is omitted;
- an explicit declaration loader overrides the card-local callback;
- explicit private loaders dispatch correctly;
- shared module loaders dispatch correctly if supported;
- shared cards can distinguish originating controllers, actions, parameters,
  and image roles without reading raw `conn.private` keys;
- duplicate declarations fail with a useful error;
- invalid card modules, options, suffixes, parameter names, and loader arities
  fail clearly;
- compile order does not change declaration IDs.

### HTML lifecycle

- a normal request calls the controller action;
- a normal request does not call the image loader;
- head metadata contains the selected strategy's absolute image URL;
- signing occurs only when metadata is requested;
- repeated metadata access within one response reuses the signed URL;
- Open Graph and Twitter roles receive distinct URLs where required;
- no image metadata is added to unrelated actions.

### Path lifecycle

- an image request calls the loader but not the normal action;
- static, dynamic, nested, scoped, and prefixed page routes work;
- path and query parameters reach the loader according to policy;
- Open Graph and Twitter requests select the correct card;
- malformed, replayed, mismatched, and unknown tokens return `404`;
- output format and dimensions cannot be changed by URL manipulation;
- application route conflicts are rejected or use the documented fallback
  prefix;
- verified routes and endpoint host/path-prefix configuration produce correct
  URLs.

### Query lifecycle

- an image query is intercepted before action dispatch;
- a normal request without the internal parameter reaches the action;
- application query parameters are preserved;
- the internal parameter is not passed to the loader;
- only allowlisted query parameters affect identity;
- tracking parameters do not create new image identities by default;
- duplicate internal parameters and parameter-name conflicts are handled
  safely;
- CDNs receive documented cache headers suitable for query-keyed responses.

### Loader failures

- every documented error tuple maps to its response status;
- exceptions, exits, and throws produce non-cacheable `503` responses;
- forbidden and invalid-token responses do not reveal record existence;
- invalid successful results such as `{:ok, []}` produce a structured failure;
- loader failures never affect an independent HTML request;
- logs and telemetry exclude signed tokens and assigns.

### Signing and security

- tokens are scoped to page path, declaration, role, dimensions, and format;
- selected query parameters are signed;
- a token cannot be replayed against another controller action;
- a token cannot change Open Graph into Twitter output;
- a token cannot select an arbitrary module or create an atom;
- declaration ID collisions fail at startup or compilation;
- signing-key rotation behavior matches documentation;
- token length remains within the documented target.

### Caching

- equivalent requests share a generated-image cache entry;
- different content versions produce different URLs and cache keys;
- renderer and embedded-resource versions remain part of cache identity;
- unsuccessful loader and renderer results are not stored as successful images;
- path and query strategies produce equivalent card output for the same
  declaration and assigns.

### Integration applications

Add demo coverage for:

- a path-mode controller with a deliberately expensive HTML action and a small
  image loader;
- a query-mode controller using the same card;
- a controller with separate square Twitter output;
- nested resource parameters;
- a loader returning `:not_found`;
- endpoint deployment below a URL path prefix.

The demos should record call counters or log markers so it is visibly provable
that image requests do not execute the HTML action.

## Implementation sequence

### Phase 1: Declaration metadata and loader dispatch

- implement `og_card/2` and `og_card/3`;
- accumulate and validate controller declarations;
- generate stable declaration IDs;
- add optional card-local `load/2`;
- generate dispatch that prefers an explicit declaration loader and otherwise
  calls the card-local loader;
- expose trusted origin controller, action, parameters, and image role through
  stable helpers or the selected request-context API;
- define loader results and errors;
- add unit tests without changing request routing.

Deliverable: declarations and loaders can be inspected and invoked in tests.

### Phase 2: Query-mode routing

- add early controller interception;
- introduce declaration-based signed tokens;
- implement allowed query-parameter normalization;
- call the loader without calling the action;
- reuse current rendering and cache infrastructure;
- preserve legacy query tokens during migration.

Deliverable: query mode works end to end and proves the action-skipping
lifecycle before path routing is introduced.

### Phase 3: Phoenix router spike

- prototype `use OgEx.Router`;
- prototype explicit `og_ex_routes()`;
- test suffix routes against Phoenix static, dynamic, nested, scoped, and
  catch-all routes;
- decide between same-page suffixes and a reserved `/_og_ex` prefix;
- document the decision and rejected alternatives.

Deliverable: a tested route design, not yet necessarily a stable public API.

### Phase 4: Path-mode routing

- implement the selected router integration;
- generate same-page or reserved-prefix URLs;
- connect declaration lookup and loader dispatch;
- add conflict detection;
- add endpoint prefix and verified-route coverage;
- make `:path` the default only after the integration is reliable.

Deliverable: both route strategies work with equivalent output.

### Phase 5: Errors, telemetry, and fallback integration

- implement the documented loader response mapping;
- add controlled exception boundaries;
- emit loader and verification telemetry;
- integrate the failure-isolation policy from `todo/image_plan.md`;
- add verified fallback images if they fit the release scope.

Deliverable: production-safe failure behavior with observable, sanitized events.

### Phase 6: Documentation and demos

- add a migration guide from `render(..., og: Card)`;
- document path and query tradeoffs;
- document loader authentication constraints;
- show complete controller, loader, card, router, and configuration examples;
- capture generated image outputs;
- deploy path and query demos using the released dependency.

Deliverable: a developer can adopt the DSL without reading internal
architecture documents.

## Versioning recommendation

The controller DSL, loader contract, and automatic image routing are substantial
new public APIs. They should ship as a minor pre-1.0 release, tentatively
`0.3.0`, rather than a `0.2.x` patch.

A possible scope:

- `0.3.0`: controller declarations, loaders, query mode, path mode, migration
  compatibility, and core error handling;
- `0.3.x`: compatibility fixes discovered in real Phoenix route layouts;
- a later minor release: fallback policies, advanced per-role loaders, and
  conditional card declarations if they are not ready for `0.3.0`.

Do not tag the version until:

- released-package demos pass for both URL strategies;
- all supported native archives exist;
- the release workflow creates one consolidated GitHub release;
- the Hex dry run contains the new documentation and examples.

## Open decisions

Resolve these through implementation spikes before freezing the API:

1. Should router integration use `use OgEx.Router` or explicit
   `og_ex_routes()`?
2. Can same-page suffix routes be implemented without unsafe catch-all routing?
3. Should path URLs include a format extension?
4. Which query parameters participate in card identity by default?
5. How does the HTML request obtain metadata and content version without
   executing the image loader?
6. Should remote shared loaders ship in the first DSL release?
7. Should loader `:forbidden` map to `404` unconditionally?
8. Should declaration tokens expire, or rely solely on version changes and key
   rotation?
9. How long must legacy query tokens remain valid?
10. Do conditional cards belong in the initial API?
11. Should fallback images be part of `0.3.0` or a follow-up release?
12. What token-size target should be enforced in tests?
13. Should card loaders receive `(conn, params)` with stable OgEx accessors, or
    one explicit `%OgEx.Request{}` context?
14. When separate Open Graph and Twitter card modules are declared without an
    explicit loader, should each card load independently or may the declaration
    designate one card as the shared data owner?

## Completion criteria

The feature is complete when:

- a controller action can declare only a card when that card implements
  `load/2`;
- an explicit controller loader can override card-local loading;
- a shared card can inspect the trusted originating route and parameters;
- image requests never execute the normal page action;
- applications can choose `:path` or `:query` globally and per declaration;
- path mode requires at most one application-wide router integration;
- query mode intercepts safely before action dispatch;
- signed URLs are short, opaque, lazy, role-bound, and route-bound;
- loader errors and exceptions produce documented, non-cacheable responses;
- normal HTML responses remain independent from image-generation failures;
- Open Graph and Twitter cards can share or select separate card modules;
- existing OgEx integrations have a documented migration path;
- scoped, nested, prefixed, and dynamic Phoenix routes are tested;
- complete examples and deployed demos prove both lifecycles.
