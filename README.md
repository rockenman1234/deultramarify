# deultramarify

Undo an Ultramarine Linux install and end up on plain Fedora with the same desktop.

Ultramarine is Fedora underneath, but it swaps in its own release packages, logos and backgrounds, patches a handful of desktop packages, and pulls Mesa from Terra. This script puts the Fedora versions back and then stages an offline upgrade to the newest stable Fedora, so everything lands in one reboot.

It works on all four current editions. The edition is read from `/etc/os-release` and the installed `ultramarine-release-*` package, then mapped to the matching Fedora spin: Plasma becomes `fedora-release-kde-desktop`, GNOME becomes `fedora-release-workstation`, Budgie becomes `fedora-release-budgie`, and Xfce becomes `fedora-release-xfce`. Older Flagship installs are treated as Budgie. There is nothing to edit in the script.

## Running it

Always start with the check pass:

```bash
sudo ./deultramarify.sh --check
```

That runs the preflight checks and every DNF dry run, prints the transaction summaries, and makes no changes. It needs DNF 5, root, network access to the Fedora repos, at least 15 GiB free on `/` and 500 MiB on `/boot`, and a Fedora base no more than one release behind the current stable one.

If the plans look right, run the real thing:

```bash
sudo ./deultramarify.sh
```

It asks once before changing anything and once more before rebooting. Decline the reboot and the downloaded transaction stays staged; run `sudo dnf system-upgrade reboot` later when it suits you, or `sudo dnf system-upgrade clean` to throw it away. `sudo ./deultramarify.sh --yes` skips both prompts and reboots as soon as the download finishes.

## What it changes

The Ultramarine release package is swapped for the Fedora one, and the upgrade is pinned to that spin so DNF can't quietly pick a different edition. Branding packages come from Fedora. Anything carrying Ultramarine or Terra branding is inspected: if Fedora has a build of the same package, it gets distro-synced back to the Fedora version; if not, it's removed. That covers the patched KDE, GNOME and Xfce settings packages and Terra Mesa without hardcoding a list per desktop. Repos, signing keys and leftover branding files go too.

RPM Fusion and your third-party apps are left alone. Terra-only extras such as starship, system76-scheduler and the extra fonts/udev rules disappear, as do Ultramarine's BBR and MTU sysctl tweaks — Fedora defaults apply afterwards. Wallpaper settings are the only thing touched in your home directory, and only if they actually point at an Ultramarine wallpaper; GNOME and Budgie keep their wallpaper in dconf, which the script leaves alone.

Before anything is modified, `/etc`, the boot entries, GRUB config, package lists and the affected user config files are copied to `/var/backups/deultramarify-<timestamp>/`. The full run log sits in `/var/log/deultramarify-<mode>-<timestamp>.log`.

## After the reboot

Run the generated check script:

```bash
sudo /root/deultramarify-postcheck.sh
```

It prints the release, the release providers, any remaining Ultramarine/Terra packages or repos, failed units, boot entry titles and `dnf check` output. Worth a look before you remove the backups.

## License

Apache License 2.0. See [LICENSE](LICENSE).
