# Sniff for Omarchy

The bar widget and panel are a QML frontend running inside `omarchy-shell`.
Every scan, rule, plan and removal is done by the `sniff` binary (Rust, in
`rust/` of this repository). The panel only runs fixed `sniff` commands with
argument lists, never through a shell, and shows their JSON.

- Left click: open or close the panel. Middle click: quick cache scan.
- Panel keys: `↑/↓` or `j/k` move, `←/→` or `f` change filter, `Space` select,
  `Enter` details, `r` scan caches, `R` full scan, `w` scan worktrees,
  `/` search, `p` review cleanup, `Tab` next bar panel, `Esc` back/close.
- Summon from a keybinding or script:
  `omarchy-shell shell summon io.github.johnrenatodev.sniff '{}'`.

Settings (Setup › Bar, or the widget entry in `~/.config/omarchy/shell.json`):
`sniffBinary` (default `sniff`), `language` (`auto`, `en`, `pt`, `es`) and
`reduceMotion` (`auto` follows Hyprland `animations:enabled`).

The dog moves only while a scan, plan or cleanup command is running, and is
still when Reduce motion applies. Install and removal steps are in
`docs/linux/install.md`.
