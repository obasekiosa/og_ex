# Native distribution

OgEx uses `RustlerPrecompiled` so ordinary Hex consumers download a native
artifact instead of compiling Takumi and the OgEx NIF locally.

## Consumer installation

Released versions require only the Hex dependency:

```elixir
{:og_ex, "~> 0.1"}
```

During `mix compile`, `RustlerPrecompiled` selects the current operating system,
CPU architecture, and NIF ABI, downloads the corresponding GitHub release
archive, and verifies it against the checksum metadata shipped in the Hex
package.

Rust is required only when developing OgEx, using an unsupported target, or
forcing a source build:

```bash
OG_EX_BUILD=true mix compile
```

Source builds currently require the Rust version pinned in
`rust-toolchain.toml`.

## Supported release targets

The `0.1` release workflow builds NIF ABI 2.15 archives for:

- Linux GNU on x86-64 and ARM64.
- Linux musl on x86-64 and ARM64.

NIF 2.15 remains compatible with newer NIF 2.x runtimes. New targets can be
added to the workflow and native-module configuration without changing the
Elixir renderer API. macOS and Windows currently use the documented source-build
path until their precompiled CI targets are validated.

## Maintainer release flow

1. Replace the development version in `mix.exs` with a release version such as
   `0.1.0`.
2. Run the complete Elixir and Rust test suites.
3. Commit the version and tag it as `v0.1.0`.
4. Push the commit and tag to GitHub.
5. Wait for `.github/workflows/release.yml` to attach every native archive to
   the GitHub release.
6. Generate the mandatory checksum metadata:

   ```bash
   mix rustler_precompiled.download OgEx.Native --all --print
   ```

7. Confirm the checksum file is included:

   ```bash
   mix hex.build --unpack
   ```

8. Publish with `mix hex.publish`.

Do not publish a stable Hex release before every advertised archive and the
generated `checksum-Elixir.OgEx.Native.exs` file are available. Development
versions intentionally force local source compilation, allowing this repository
and path dependencies to work before release assets exist.
