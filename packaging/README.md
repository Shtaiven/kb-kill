# Packaging kb-kill

kb-kill is **noarch** (pure Python + shell + systemd units + SVGs), so packages
just place files and run systemd scriptlets. Two toolchains cover three formats:

| Format         | Tool                                 | Files                                               |
| -------------- | ------------------------------------ | --------------------------------------------------- |
| `.deb`, `.rpm` | [nfpm](https://nfpm.goreleaser.com/) | `nfpm.yaml`, `scriptlets/*.sh`, `build-packages.sh` |
| AUR            | `makepkg`                            | `aur/PKGBUILD`, `aur/kb-kill.install`               |

AUR ships a *recipe* (PKGBUILD), not a built artifact — that's why it's separate.

All three install to `/usr` (not `/usr/local`, which is reserved for the local
admin and off-limits to package managers). The repo's systemd units and
`.desktop` files point at `/usr/local/*` for `install.sh`; both build paths
rewrite those to `/usr/*`.

## Versioning (single source of truth)

The `VERSION` file at the repo root is canonical. The `VERSION = "..."`
constants in the three scripts (what `--version` prints) and `pkgver=` in
`aur/PKGBUILD` are copies kept in sync by `bump-version.sh`; the release
workflow runs `bump-version.sh --check <tag>` before building, so a tag that
disagrees with any copy fails the release. README install commands use
wildcards instead of version literals so the docs can't rot.

## Cutting a release

```sh
packaging/bump-version.sh 0.3.0    # rewrites VERSION + every synced copy
                                   # (or --patch / --minor / --major to auto-increment)
git commit -am "chore: release 0.3.0"
git tag v0.3.0 && git push origin main v0.3.0   # CI builds + attaches .deb/.rpm
# AUR, after the tag is published:
cd packaging/aur && updpkgsums && makepkg --printsrcinfo > .SRCINFO
```

## Build .deb + .rpm

```sh
# install nfpm once: https://nfpm.goreleaser.com/install/ (single static binary)
packaging/build-packages.sh        # -> packaging/dist/*.deb, *.rpm
                                   # version defaults to the VERSION file
```

## Build / publish the AUR package

```sh
cd packaging/aur
updpkgsums          # fills in the source sha256 (needs a published v$pkgver tag)
makepkg -si         # local build + install test
makepkg --printsrcinfo > .SRCINFO
# then push PKGBUILD + .SRCINFO + kb-kill.install to the AUR git repo
```

## Notes

- The AUR source pulls `github.com/Shtaiven/kb-kill/archive/refs/tags/v$pkgver.tar.gz`,
  so a matching `v$pkgver` git tag must exist before `updpkgsums`/`makepkg`.
- deb/rpm scriptlets auto-enable the daemon and `--global enable` push/tray
  (matching `install.sh`). The AUR `.install` follows Arch convention and only
  *prints* the enable commands instead of running them.
- The MIT `LICENSE` ships to `/usr/share/licenses/kb-kill/LICENSE`.
