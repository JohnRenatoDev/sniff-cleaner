# Install Sniff on Omarchy

Requirements: Omarchy 4 (tested with 4.0.6, `omarchy-shell` plugins),
Rust 1.88 or newer through `rustup` (tested with 1.88), and `git`. No root access is needed.

## Install from a checkout

```sh
git clone https://github.com/JohnRenatoDev/sniff-cleaner.git ~/Work/sniff-cleaner
cd ~/Work/sniff-cleaner
./script/omarchy_install.sh --enable
```

The script:

1. builds `sniff` with `cargo build --release --locked` at `nice 19`;
2. installs it as `~/.local/bin/sniff`, refusing to replace a file it did not
   install (`--force-binary` overrides);
3. copies `manifest.json`, `LICENSE` and `omarchy/` to
   `~/.config/omarchy/plugins/io.github.johnrenatodev.sniff/`;
4. runs `omarchy plugin validate` on the copy and asks the shell to rescan;
5. with `--enable`, adds the widget to the right side of the bar
   (`omarchy plugin enable io.github.johnrenatodev.sniff --section right`).

It does not run `sudo`, register the scheduler, scan or clean. Without
`--enable`, enable it later with `omarchy plugin enable io.github.johnrenatodev.sniff`.
If `~/.local/bin` is not on `PATH`, set the widget's *sniff command* setting
to the full path.

Run the script again to update both the binary and the plugin.

### With `omarchy plugin add`

Omarchy can also clone the repository as a plugin (it needs `manifest.json`
at the root, which this branch adds). That installs only the QML frontend; the
`sniff` binary still has to be built and placed on `PATH`:

```sh
omarchy plugin add https://github.com/JohnRenatoDev/sniff-cleaner.git
cd ~/.config/omarchy/plugins/io.github.johnrenatodev.sniff/rust && cargo build --release
install -m 0755 "$(cargo metadata --format-version 1 --no-deps | jq -r .target_directory)/release/sniff" ~/.local/bin/sniff
```

This only works once the plugin files are on the repository's default branch.

## Uninstall

```sh
./script/omarchy_uninstall.sh          # keeps settings and history
./script/omarchy_uninstall.sh --purge  # also removes ~/.config/sniff and ~/.local/state/sniff
```

It disables Sniff's systemd timer if one was registered, disables the bar
widget, removes the plugin folder (only if its manifest is Sniff's) and the
binary installed by the script.

## Scheduling

Scheduling is off. To enable it:

```sh
sniff schedule enable --mode analyze           # scans only; review later
sniff schedule enable --mode automatic         # also cleans enabled regenerable caches
sniff schedule status
sniff schedule disable
```

`enable` writes `~/.config/systemd/user/sniff-scheduler.{service,timer}`
(marked as managed by Sniff), reloads the user manager and enables the timer.
`status` reads `systemctl --user show`, so a saved setting alone is never
reported as working. The user manager must be running (you must be logged in
unless lingering is enabled).

## Verify

```sh
./script/linux/test.sh            # fmt, clippy, tests, plugin validation
./script/linux/test_scheduler.sh  # temporary timer in fixture mode, then removed
omarchy plugin list | grep sniff
omarchy-shell shell summon io.github.johnrenatodev.sniff '{}'
```
