# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased] — v0.5.0 (in progress)

No work has started yet. Items carried from v0.4.1:
- On live booths: remove `/opt/run_booth.py`, `/opt/clear_booth.py`, and
  the legacy `/boot/src/photobooth/` source tree.
- Drop `StandardOutput=append:/var/log/booth_stdout.log` from the
  generated `booth.service` unit (nothing writes there now that v0.4.0
  converted all `print()` calls to logger calls).
- Delete `booth_boot/resources/booth_init.deprecated.py` (named
  `.deprecated` since the 2021 initial upload; no consumer in the repo).
- Apply the v0.4.1 active-low button rewire to the red and green buttons
  on the live booth (capture button done; topology documented in
  `HARDWARE.md`).
- Finish sizing the ATX dummy load to stop the LED-flutter-on-shutdown.
  v0.4.1 attempts ladder up via parallel 220 Ω 1/4 W resistors; next
  step is a 10 Ω 5 W ceramic if parallel stacking is insufficient.

## [v0.4.1] — 2026-05-27

Slim-down release. v0.4.0 left several rollback artifacts in place
intentionally so a Pi could be reverted from the new pip-install model
to the old SFTP-into-`/opt/` model if anything broke in the field. With
v0.4.0 running cleanly on the live booth for ~5 days, the rollback path
is removed and the first hardware reference doc lands.

### Added
- `HARDWARE.md` — booth electrical reference. Currently scoped to button
  wiring (the v0.4.1 active-low topology, parts list, cat5e pair
  assignment, per-button validation status) and the in-progress ATX
  dummy-load sizing. Expands as other subsystems are validated.
- `README.md`: link to `HARDWARE.md` from a new "Hardware reference"
  section so it's discoverable.

### Removed
- `booth_boot/resources/run_booth.py` and `booth_boot/resources/clear_booth.py`
  (the pre-v0.4.0 entry scripts; kept through v0.4.0 as a rollback hint, now
  gone — the runtime lives in the `photobooth` package).
- The commented-out `# sudo cp /boot/resources/{run_booth,clear_booth}.py /opt/`
  block from `init_setup.sh`.
- The `/boot/zen_api_pw` reading block from `init_setup.sh` — the v0.4.0
  console scripts do not consume it.

## [v0.4.0] — 2026-05-20

Deployment model switched from "SFTP `.py` files into `/opt/`" to
"`pip install` from a public git tag". Per-booth runtime configuration now
lives in `/etc/ctp/booth.env`, loaded by systemd, instead of being hardcoded
into the runtime script.

### Added
- `booth_boot/resources/booth.env.example` — documented template for
  `/etc/ctp/booth.env`. Covers all seven consumable `BOOTH_*` keys
  (`BOOTH_S3_BUCKET`, `BOOTH_IMAGE_DIR`, `BOOTH_CAMERA_MODEL`,
  `BOOTH_MAX_PRINTS`, `BOOTH_TEMPLATE_BASE_DIR`, `BOOTH_ACTIVE_TEMPLATE`,
  `BOOTH_LOG_LEVEL`). Each is commented out; uncommenting overrides the
  Python-level default in `photobooth/booth_main.py`.
- `init_setup.sh` scaffolds `/etc/ctp/` and seeds `booth.env.example` into it
  during first-boot provisioning.

### Changed
- `init_setup.sh` now runs
  `sudo pip3 install "git+https://github.com/capturingtime/photobooth.git@${branch}"`
  (non-editable) to install the booth runtime, instead of copying
  `run_booth.py` / `clear_booth.py` into `/opt/`.
- The generated `/lib/systemd/system/booth.service` unit now points at the
  pip-installed console scripts:
  - `ExecStart=/usr/local/bin/photobooth-run`
  - `ExecStopPost=/usr/local/bin/photobooth-clear`
  - `EnvironmentFile=-/etc/ctp/booth.env` (the leading `-` makes it optional)
  - `Environment=PYTHONUNBUFFERED=1` so logger output flushes promptly
  - `StandardError=journal` so the photobooth logger's WARN+ stream reaches
    `journalctl -u booth.service`
- README rewritten around the pip-install deployment model and the
  `/etc/ctp/booth.env` configuration story.

### Removed (from the deployment path; files retained as rollback artifacts)
- `init_setup.sh` no longer copies `booth_boot/resources/run_booth.py` or
  `clear_booth.py` to `/opt/`. The lines are commented out rather than
  deleted; the script files themselves remain in `booth_boot/resources/` for
  rollback. Both will be removed outright in v0.4.1.

### Breaking
- **Legacy Zenfolio CLI args are gone from the generated `ExecStart`.** The
  v0.2.0-era `run_booth.py` accepted `-x`/`-u`/`-p` to inject Zenfolio
  credentials at runtime; the v0.4.0 console scripts take no such arguments.
  `init_setup.sh` no longer wires those flags into the unit.
- **Previously provisioned booths require a manual migration** — re-running
  `init_setup.sh` end-to-end is not the supported upgrade path. See below.

### Fixed
- **`booth.service` symlink integrity.** A `sed -i` against
  `/etc/systemd/system/booth.service` had silently turned a symlink into a
  divergent regular file. The unit is now written canonically to
  `/lib/systemd/system/booth.service` and the `/etc/` copy is a symlink.
- **WARN+ not reaching journald.** `StandardError=append:` on the previous
  unit captured the photobooth logger's stderr stream into a file and never
  forwarded it to journald. Switched to `StandardError=journal`.

### Upgrade for existing booths

Re-running `init_setup.sh` end-to-end on a live booth is not the supported
path (it re-provisions too much). The minimum migration is:

```sh
ssh pi@<booth>

# Buster ships pip 18.x which doesn't speak PEP 517 — upgrade once first.
sudo pip3 install --upgrade pip setuptools wheel

# If psutil was previously installed via apt:
sudo pip3 install --ignore-installed psutil

# Install the runtime from the v0.4.0 tag (pulls ctp-utilities@v0.4.0 transitively).
sudo pip3 install --upgrade --force-reinstall \
    "git+https://github.com/capturingtime/photobooth.git@v0.4.0"

# Scaffold the env file (start empty; defaults in booth_main.py apply).
sudo mkdir -p /etc/ctp
sudo touch /etc/ctp/booth.env

# Replace the booth.service unit with the v0.4.0 template (see
# booth_boot/init_setup.sh for the canonical content).
sudo cp /path/to/new/booth.service /lib/systemd/system/booth.service
sudo systemctl daemon-reload
sudo systemctl restart booth.service
```

### Known leftover state on previously provisioned booths
- `/opt/run_booth.py` and `/opt/clear_booth.py` still exist on disk but are no
  longer the runtime. Safe to delete; will be removed during v0.4.1 cleanup.
- `/boot/src/photobooth/` may still exist as a legacy source-checkout tree.
  Not consumed by v0.4.0. Will be removed during v0.4.1 cleanup.
- `/boot/zen_api_pw` is still read by `init_setup.sh` but the value is not
  used anywhere downstream. Cleanup pending in v0.4.1.

## Pre-v0.4.0 history (untagged)

No releases were tagged before v0.4.0. The repo evolved in two clusters:

- **2021-05 to 2021-06 — initial provisioning kit (`4a6d5c0` → `1f30a58`).**
  `1f30a58` ("Initial Upload") established the three Pi roles: `booth_boot/`
  (photobooth role with `init_setup.sh`, `run_booth.py`,
  `clear_booth.py`, the `kiosk` launcher, and a `zen_api_pw` secret),
  `display_boot/` (digital-signage role with `display_marketing_*.jpg` assets
  and a `provision_display` script), and `multi_boot/` (Syncthing-based
  multi-Pi sync with `wpa_supplicant.conf`, `static_ip`, and a
  `syncthing_device_mgr`).
- **2026-05 — v0.4.0 prep + rewrite (`5b6f368` → `ef9b640`).** `861516a`
  ("major revisions for nextgen of booth, claude assisted") substantially
  rewrote `run_booth.py` (792 lines changed). The remaining v0.4.0 commits
  pivoted off this rewrite and into the pip-install / env-var / systemd-unit
  work captured under [v0.4.0] above.
