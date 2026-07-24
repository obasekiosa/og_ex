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

The release workflow builds NIF ABI 2.15 archives for:

- Linux GNU on x86-64 and ARM64.
- Linux musl on x86-64 and ARM64.
- macOS on Intel and Apple Silicon.
- Windows MSVC on x86-64.

NIF 2.15 remains compatible with newer NIF 2.x runtimes. New targets can be
added to the workflow and native-module configuration without changing the
Elixir renderer API.

## Maintainer release flow

1. Replace the development version in `mix.exs` with a release version such as
   `0.1.0`.
2. Run the complete Elixir and Rust test suites.
3. Commit the version and tag it as `v0.1.0`.
4. Push the commit and tag to GitHub.
5. Wait for `.github/workflows/release.yml` to attach every native archive,
   generate their checksum metadata, test the released NIF, and publish the
   package and documentation to Hex.

The `publish_hex` job runs only after every native target succeeds and uses the
protected `hex-production` GitHub environment. Configure that environment with
a `HEX_API_KEY` secret restricted to `api:write`; an optional required-reviewer
rule can keep publication subject to maintainer approval.

For a manual recovery release, generate the mandatory checksum metadata after
the final artifacts have been attached:

   ```bash
   mix rustler_precompiled.download OgEx.Native --all --print
   ```

Then confirm the checksum file is included:

   ```bash
   mix hex.build --unpack
   ```

Finally publish with `mix hex.publish`.

Do not publish a stable Hex release before every advertised archive and the
generated `checksum-Elixir.OgEx.Native.exs` file are available. Development
versions intentionally force local source compilation, allowing this repository
and path dependencies to work before release assets exist.
