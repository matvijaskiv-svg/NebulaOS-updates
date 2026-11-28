# NebulaOS updates

What installed NebulaOS systems download. Nothing to edit here by hand.

- `channel/channel.json` + `channel.sig` — news, polls, official groups, ban list, wallpaper of the week.
  Every NebulaOS accepts it only with the maintainer's Ed25519 signature.
- Release `repo` — the pacman repository `[nebulaos]` used by `nebula update`.
- `install.sh` — NebulaOS on an existing Arch-based system (Garuda, EndeavourOS, CachyOS, Arch)
  without reinstalling: apps and files stay, `sudo nebulaos-undo` goes back.

      curl -fsSLO https://raw.githubusercontent.com/matvijaskiv-svg/NebulaOS-updates/main/install.sh
      bash install.sh

- `dualboot.sh` — NebulaOS next to Garuda (or any Arch-based system on btrfs), chosen in the boot menu.
  No USB stick, no repartitioning: own btrfs subvolumes. `sudo bash dualboot.sh remove` deletes it again.

      curl -fsSLO https://raw.githubusercontent.com/matvijaskiv-svg/NebulaOS-updates/main/dualboot.sh
      sudo bash dualboot.sh
