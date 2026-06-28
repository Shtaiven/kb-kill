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

## Build .deb + .rpm

```sh
# install nfpm once: https://nfpm.goreleaser.com/install/ (single static binary)
packaging/build-packages.sh 0.1.0      # -> packaging/dist/*.deb, *.rpm
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
