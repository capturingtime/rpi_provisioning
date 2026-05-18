# rpi_provisioning

Scripts and service files for Raspberry Pis running photobooth or signage roles.

## booth_boot

Provisions and runs the photobooth service on a Raspberry Pi 4B.

```
booth_boot/
  resources/
    run_booth.py      ← asyncio booth entry point (deployed to /opt/run_booth.py)
    kiosk.sh          ← (see photobooth/photobooth/resources/kiosk.sh — source of truth)
```

### Deployment

Files are deployed to the Pi via SFTP to `/home/pi/booth_staging/`, then `sudo cp`
to their final destinations (Pi files are owned by root):

| Source | Pi destination |
|---|---|
| `run_booth.py` | `/opt/run_booth.py` |
| `photobooth/` package | `/boot/src/photobooth/` |
| Compositor templates | `/opt/photobooth/templates/` |

The booth runs as a systemd service (`/lib/systemd/system/booth.service`).
Logs: `/var/log/booth_stdout.log`.

### Configuration

All runtime configuration is at the top of `run_booth.py`:

| Constant | Purpose |
|---|---|
| `S3_BUCKET` | Public S3 bucket for uploads |
| `BOOTH_DIR` | Local archive directory for captured images |
| `CAMERA_MODEL` | gphoto2 camera model string |
| `CAMERA_STARTUP_CONFIG` | Per-camera gphoto2 settings applied at startup |
| `ACTIVE_TEMPLATE` | Compositor template name (`None` = plain single-shot) |
| `TEMPLATE_BASE_DIR` | Root directory for compositor templates on the Pi |
| `MAX_PRINTS` | Maximum receipt reprints per image |

See [photobooth/ARCHITECTURE.md](../photobooth/ARCHITECTURE.md) for full documentation.
