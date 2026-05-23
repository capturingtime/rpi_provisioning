# rpi_provisioning

OS-side glue for the Raspberry Pis that run photobooth or signage roles: systemd
service units, kiosk launchers, first-boot setup scripts. The Python application
code itself lives in the `photobooth` repo and is installed via pip.

## booth_boot

Provisions and runs the photobooth service on a Raspberry Pi 4B.

```
booth_boot/
  init_setup.sh       ← first-boot provisioning: apt deps, pip install, service-unit gen
  resources/
    kiosk             ← X11 kiosk launcher (sourced by xinit)
    booth.env.example ← documented template for /etc/ctp/booth.env
```

### Deployment model

The photobooth runtime is the `photobooth-run` console script (entry point in the
`photobooth` package). The booth gets it via `pip install` from a public git tag:

```sh
sudo pip3 install "git+https://github.com/capturingtime/photobooth.git@vX.Y.Z"
```

This pulls `ctp-utilities` as a transitive dep from its matching tag. `init_setup.sh`
runs this command (against `${branch}`) during first-boot provisioning and generates
`/lib/systemd/system/booth.service` with `ExecStart=/usr/local/bin/photobooth-run`
and `ExecStopPost=/usr/local/bin/photobooth-clear`.

### Updating the booth between versions

After bumping a tag in `photobooth` (or `utilities`):

```sh
sudo pip3 install --upgrade --force-reinstall \
    "git+https://github.com/capturingtime/photobooth.git@vX.Y.Z"
sudo systemctl restart booth.service
```

### Configuration

Runtime configuration constants (`S3_BUCKET`, `BOOTH_DIR`, `CAMERA_MODEL`,
`CAMERA_STARTUP_CONFIG`, `ACTIVE_TEMPLATE`, `TEMPLATE_BASE_DIR`, `MAX_PRINTS`,
button labels, screen URLs) live at the top of `photobooth/photobooth/booth_main.py`
in the `photobooth` repo. (Workstream B will move these to a `/etc/ctp/booth.env`
file consumed via systemd `EnvironmentFile=`.)

Templates (compositor PNG + JSON sidecar pairs) are deployed out-of-package to
`/opt/photobooth/templates/` so they can be swapped without a pip re-install. See
[photobooth/ARCHITECTURE.md § Template System](../photobooth/ARCHITECTURE.md) for
the schema.

Logs: `/var/log/booth_stdout.log` (appended via the service unit).
