# Clang ThinLTO kernel builds

GCC remains the default toolchain for every build entry point. Setting
`KERNEL_TOOLCHAIN=clang` switches a build to Clang/LLVM and enables ThinLTO; no
other input changes, and the resulting packages keep the same payload layout,
package names, and boot behaviour as a GCC build.

## Selecting the toolchain

| Variable | Values | Default | Effect |
| -------- | ------ | ------- | ------ |
| `KERNEL_TOOLCHAIN` | `gcc`, `clang` | `gcc` | Compiler/binutils family for the standard and EL2 variants |
| `KERNEL_LTO` | `thin`, `none` | `thin` when `KERNEL_TOOLCHAIN=clang`, otherwise `none` | `thin` selects ThinLTO; `none` keeps LTO off |
| `KERNEL_TUNE` | a CPU name (`cortex-x1`, `cortex-a78`, ...) or `sc8280xp` | unset | Appends `KCFLAGS=-mtune=<cpu>`; unset keeps the portable armv8-a baseline |

`KERNEL_LTO=thin` with `KERNEL_TOOLCHAIN=gcc` is rejected, because
`CONFIG_LTO_CLANG_THIN` needs the Clang toolchain.

Local pinned build:

```bash
KERNEL_TOOLCHAIN=clang BUILD_EL2=true ./build.sh debs
```

Legacy on-device helper:

```bash
export KERNEL_TOOLCHAIN=clang
export KERNEL_LTO=thin
export KERNEL_TUNE=sc8280xp      # opt-in: KCFLAGS=-mtune=cortex-x1
export INSTALL_DEPS=true          # installs clang, lld, and llvm
scripts/local/build_kernel.sh < /dev/null
```

The `checks.yml` workflow additionally runs `shellcheck` over
`scripts/ci/lib/toolchain.sh`, and the package workflows expose a
`kernel_toolchain` dispatch input.

## Exact make invocation

In Clang mode the shared resolver `scripts/ci/lib/toolchain.sh` sets
`KERNEL_MAKE_ARGS` to:

```
LLVM=1 LLVM_IAS=1 LD=ld.lld
```

When `KERNEL_TUNE` is set it appends one more entry:

```
KCFLAGS=-mtune=<cpu>
```

so the same array carries the toolchain and the tuning into every make call.

- `scripts/ci/20_build_kernel_variants.sh`: `gaokun3_defconfig`, `olddefconfig`,
  the parallel build, `modules_prepare`, the EL2 source `clean`, and both
  variants (standard and EL2 use the one `build_variant` function, so they
  cannot diverge).
- `scripts/ci/70_build_package_debs.sh` and
  `scripts/ci/70_build_package_rpms.sh`: `modules_install`.
- `scripts/local/build_kernel.sh`: the same set of calls.

The flags mean:

- `LLVM=1` selects clang, `ld.lld`, `llvm-ar`, `llvm-nm`, `llvm-objcopy`,
  `llvm-strip`, and the rest of one LLVM release, so the assembler, linker, and
  binutils stay in step.
- `LLVM_IAS=1` uses clang's integrated assembler instead of GNU as, so no
  aarch64 GNU binutils package is needed for assembly.
- `LD=ld.lld` pins the linker. `LLVM=1` already selects `ld.lld`, but
  `CONFIG_LTO_CLANG_THIN` hard-depends on `LD_IS_LLD`, so the linker is named
  explicitly rather than left implicit.

In GCC mode `KERNEL_MAKE_ARGS` is empty and the make command lines are byte for
byte the previous ones.

## Microarchitecture tuning (opt-in)

`KERNEL_TUNE` adds `KCFLAGS=-mtune=<cpu>` for the Snapdragon 8cx Gen 3
(SC8280XP). The alias `sc8280xp` selects the Cortex-X1 prime core; any CPU name
the compiler knows (`cortex-x1`, `cortex-a78`, ...) is accepted.

- Only `-mtune` is used, never `-march`. `-mtune` changes instruction scheduling
  but keeps the armv8-a ISA baseline and the kernel ABI, so externally built
  modules stay compatible. `-march` would let the compiler emit instructions
  that not every cluster or a differently built module supports, and is
  deliberately not offered.
- `validate_kernel_tune` compiles a trivial translation unit with the caller's
  compiler and `-mtune=<cpu>` before any variant is configured, so an
  unsupported CPU name fails immediately. It is a no-op when `KERNEL_TUNE` is
  unset.
- `KERNEL_TUNE` is not exposed as a CI workflow input: it is a local tuning
  option, and the release package sets stay portable.

## Kconfig handling and assertions

`apply_kernel_toolchain_config` runs after `gaokun3_defconfig` and before
`olddefconfig`, and in Clang ThinLTO mode:

- enables `CONFIG_LTO_CLANG_THIN`;
- clears `CONFIG_LTO_CLANG_FULL`, which shares the LTO choice, so a stale Full
  LTO selection cannot win;
- fails with an explicit message when the generated `.config` does not expose
  `CONFIG_LTO_CLANG_THIN` at all, so a kernel tree without Clang ThinLTO support
  is reported instead of silently building without LTO.

`assert_kernel_toolchain_config` runs after `olddefconfig` and fails the build
when the configured compiler is not the requested one:

- Clang mode requires `CONFIG_CC_IS_CLANG=y`, and `CONFIG_LTO_CLANG_THIN=y` when
  `KERNEL_LTO=thin`;
- GCC mode requires `CONFIG_CC_IS_GCC=y`.

The assertion catches a make call that forgot `KERNEL_MAKE_ARGS` and a missing
`ld.lld` (which makes `olddefconfig` drop ThinLTO), rather than shipping a
kernel from a mixed toolchain.

## Toolchain installation

- Debian/Ubuntu: `apt-get install clang lld llvm` (the package workflows and
  the legacy helper's `INSTALL_DEPS=true` path).
- Fedora: `dnf install clang lld llvm`; the RPM package workflow installs them
  inside the `fedora:${FEDORA_RELEASE}` container that runs the package script.

The package workflows install and print `clang --version` and `ld.lld --version`
before building, which validates the toolchain early.

## Package and release contracts

- The toolchain is recorded as `kernel_toolchain` and `kernel_lto` in
  `package-manifest.json` and listed in `package-release-body.md`.
- GCC builds keep their existing release-tag shape
  (`gaokun3-debs-<tag>[-xanmod]-<profile>-<ts>`). Clang builds append `-clang`
  after the profile, and the image workflows' release-prefix lookup adds the
  same suffix, so a Clang package set cannot be mistaken for a GCC one.
- The ccache key includes the toolchain for both package workflows, so GCC and
  Clang objects never share a cache entry.

## Limitations and unverified scope

- The package and image workflows run on `ubuntu-24.04-arm`, so the Clang
  toolchain is the distribution package at that point in time; a specific clang
  version is not pinned. The kernel's own `Kconfig` computes the minimum clang
  version for `CONFIG_LTO_CLANG` and rejects an older compiler during
  configuration.
- ThinLTO increases link time relative to a GCC build; enabling `KERNEL_LTO=none`
  with `KERNEL_TOOLCHAIN=clang` builds with clang and no LTO when link time or
  reproducibility matters more than size.
- `KERNEL_TUNE` changes only scheduling, so it does not affect the package
  manifest or artifact names; it is recorded in neither. A tuned kernel and a
  portable kernel of the same inputs produce the same package filenames, so do
  not mix them in one release without rebuilding.
- A Clang ThinLTO kernel has not been built and booted end to end in this
  checkout: no arm64 kernel checkout, cross toolchain, or device is available
  here. The authoritative validation is the `gaokun3-package-debs` or
  `gaokun3-package-rpms` workflow dispatched with `kernel_toolchain=clang`, and
  then an image workflow built from that package release and booted on the
  device.
- Existing GCC builds are unchanged: with `KERNEL_TOOLCHAIN` unset the
  `KERNEL_MAKE_ARGS` array is empty and every make command line matches the
  previous ones.
