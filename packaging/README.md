# Packaging kb-kill

kb-kill is **noarch** (pure Python + shell + systemd units + SVGs), so packages
just place files and run systemd scriptlets. Two toolchains cover three formats:

| Format         | Tool                                 | Files                                               |
| -------------- | ------------------------------------ | --------------------------------------------------- |
| `.deb`, `.rpm` | [nfpm](https://nfpm.goreleaser.com/) | `nfpm.yaml`, `scriptlets/*.sh`, `build-packages.sh` |
| AUR            | `makepkg`                            | `aur/PKGBUILD`, `aur/kb-kill.install`               |

AUR ships a *recipe* (PKGBUILD), not a built artifact, which is why it is separate.

All three install to `/usr` (not `/usr/local`, which is reserved for the local
admin). The repo's systemd units and `.desktop` files point at `/usr/local/*`
for `install.sh`; both build paths rewrite those to `/usr/*`.

## One payload, four consumers

`nfpm.yaml` is the canonical file list (deb/rpm is the primary install method).
`install.sh`, `uninstall.sh` and `aur/PKGBUILD` derive their payload from the
`scripts/`, `services/`, `desktop/` and `icons/` directories, and
`check-sync.sh` asserts all four agree:

```sh
packaging/check-sync.sh            # exit 1 on any mismatch; release.yml runs it
```

Adding a file: put it in the right directory, add its `src:`/`dst:` to
`nfpm.yaml`, run `check-sync.sh`.

## Versioning (single source of truth)

The `VERSION` file at the repo root is canonical. The `VERSION = "..."`
constant in every script (what `--version` prints) and `pkgver=` in
`aur/PKGBUILD` are copies kept in sync by `bump-version.sh`; the release
workflow runs `bump-version.sh --check <tag>` before building. README install
commands use wildcards instead of version literals.

## Cutting a release

```sh
packaging/bump-version.sh 0.5.0    # rewrites VERSION + every synced copy
                                   # (or --patch / --minor / --major)
packaging/check-sync.sh
git commit -am "chore: release 0.5.0"
git tag v0.5.0 && git push origin main v0.5.0   # CI checks, builds, attaches .deb/.rpm
# AUR, after the tag is published:
cd packaging/aur && updpkgsums && makepkg --printsrcinfo > .SRCINFO
```

## Build .deb + .rpm

```sh
# install nfpm once: https://nfpm.goreleaser.com/install/ (single static binary)
packaging/build-packages.sh        # -> packaging/dist/*.deb, *.rpm
```

## Build / publish the AUR package

```sh
cd packaging/aur
updpkgsums          # needs a published v$pkgver tag
makepkg -si         # local build + install test
makepkg --printsrcinfo > .SRCINFO
```

## Notes

- deb/rpm scriptlets enable the daemon and `--global enable` push/tray for every
  user (matching `install.sh`); `ConditionUser=!@system` in the user units keeps
  them off system accounts such as the login greeter. The AUR `.install` follows
  Arch convention and only prints the enable commands.
- The daemon unit uses `DynamicUser=yes` + `SupplementaryGroups=input`, so no
  package creates a user.
- The MIT `LICENSE` ships to `/usr/share/licenses/kb-kill/LICENSE`.
