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
| `KERNEL_TUNE` | a CPU name (`cortex-x1c`, `cortex-a78`, ...) or one of the SC8280XP aliases `sc8280xp` / `8cx-gen3` / `8cxgen3` | unset | Appends tuning to `KCFLAGS`; the SC8280XP aliases select `-march=armv8.4-a+crypto -mtune=cortex-x1c`, other values select `-mtune=<cpu>` only; unset keeps the portable armv8-a baseline |

`KERNEL_LTO=thin` with `KERNEL_TOOLCHAIN=gcc` is rejected, because
`CONFIG_LTO_CLANG_THIN` needs the Clang toolchain.

The `KERNEL_TUNE` selection is exported as the `kernel_tune` dispatch and
`workflow_call` input on the package workflows, so a dispatched run selects the
same profile a local build would. Leave it empty for the portable baseline.

Local pinned build:

```bash
KERNEL_TOOLCHAIN=clang KERNEL_TUNE=sc8280xp BUILD_EL2=true ./build.sh debs
```

Legacy on-device helper:

```bash
export KERNEL_TOOLCHAIN=clang
export KERNEL_LTO=thin
export KERNEL_TUNE=sc8280xp      # opt-in: -march=armv8.4-a+crypto -mtune=cortex-x1c
export INSTALL_DEPS=true          # installs clang, lld, and llvm
scripts/local/build_kernel.sh < /dev/null
```

The `checks.yml` workflow additionally runs `shellcheck` over
`scripts/ci/lib/toolchain.sh` and asserts the `KERNEL_TUNE` selection (the
SC8280XP profile and a bare CPU name), and the package workflows expose
`kernel_toolchain` and `kernel_tune` dispatch inputs.

## Exact make invocation

In Clang mode the shared resolver `scripts/ci/lib/toolchain.sh` sets
`KERNEL_MAKE_ARGS` to:

```
LLVM=1 LLVM_IAS=1 LD=ld.lld
```

When `KERNEL_TUNE` is set it appends one more entry. For the SC8280XP profile:

```
KCFLAGS=-march=armv8.4-a+crypto -mtune=cortex-x1c
```

For any other `KERNEL_TUNE` value:

```
KCFLAGS=-mtune=<cpu>
```

A `KCFLAGS` the caller already exported is preserved: the resolver appends the
tuning to it rather than replacing it, because a `KCFLAGS=` on the make command
line would otherwise override the environment and silently drop the caller's
flags.

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

## Target tuning (opt-in)

`KERNEL_TUNE` selects the target tuning appended to `KCFLAGS` for the Snapdragon
8cx Gen 3 (SC8280XP). Two forms are accepted:

- the explicit SC8280XP profile aliases `sc8280xp`, `8cx-gen3`, `8cxgen3`, which
  select both the ISA and the microarchitecture:
  `-march=armv8.4-a+crypto -mtune=cortex-x1c`;
- any other value, treated as a bare CPU name the compiler knows (`cortex-x1c`,
  `cortex-a78`, ...), which selects `-mtune=<cpu>` only and keeps the portable
  armv8-a ISA baseline.

ISA selection (`-march`) and microarchitecture tuning (`-mtune`) are distinct:

- `-march=armv8.4-a+crypto` sets the ISA the SC8280XP clusters implement
  (Armv8.4-A plus the crypto extension). It tells the compiler which
  instructions it may emit.
- `-mtune=cortex-x1c` only affects instruction scheduling for the Cortex-X1C
  prime core. It never changes the emitted ISA.
- The SC8280XP profile is explicit and applies only to that profile: with
  `KERNEL_TUNE` unset, or with any other CPU name, the previous portable
  behaviour is unchanged, so externally built modules stay compatible.
- `validate_kernel_tune` compiles a trivial translation unit with the caller's
  compiler, the complete `KERNEL_TUNE` flag string, and the kernel's own
  `-mgeneral-regs-only` constraint before any variant is configured, so an
  unsupported combination fails immediately. It is a no-op when `KERNEL_TUNE` is
  unset.
- `KERNEL_TUNE` is exposed as the `kernel_tune` input on the package workflows
  and defaults to empty, so a dispatched release run stays portable unless the
  caller explicitly selects a profile.

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
- `KERNEL_TUNE` is applied to the compiled objects only; it does not affect the
  package manifest or artifact names, and it is recorded in neither. A tuned
  kernel and a portable kernel of the same inputs produce the same package
  filenames, so do not mix them in one release without rebuilding.
- Selecting the SC8280XP profile changes the emitted ISA (`-march`), so its
  tuning claim is a compilation setting only. This document does not assert that
  the resulting kernel boots or is faster: those need an actual build and a boot
  on the device and are outside what this checkout can verify.
- A Clang ThinLTO kernel has not been built and booted end to end in this
  checkout: no arm64 kernel checkout, cross toolchain, or device is available
  here. The authoritative validation is the `gaokun3-package-debs` or
  `gaokun3-package-rpms` workflow dispatched with `kernel_toolchain=clang`, and
  then an image workflow built from that package release and booted on the
  device.
- Existing GCC builds are unchanged: with `KERNEL_TOOLCHAIN` unset the
  `KERNEL_MAKE_ARGS` array is empty and every make command line matches the
  previous ones.
