# Liquidctl Control for Noctalia 5

A native Luau plugin for Noctalia `v5.0.0-beta1` that:

- shows Commander Pro coolant temperature in the bar;
- shows radiator Fan 1–3 and Pump/Fan 4 RPM in the bar and popup;
- controls Commander Pro `led1`, `led2`, or both channels;
- controls the ASUS Aura waterblock interface selected with `--pick`;
- applies one Static, Pulse/Breathing, Rainbow, or Off action to every enabled lighting device.

The plugin only controls lighting. It never changes fan or pump curves, and it
does not use `--unsafe=high_temperature`.

Version `0.1.2` performs USB-backed hwmon reads outside Noctalia's time-limited
Luau callbacks and batches each lighting action into one asynchronous command.
This prevents the beta1 runtime from disabling the controller service after
repeated callback timeouts. Its panel header also provides a settings button
that opens Noctalia's Plugins settings page.

## Install

Extract the archive so the final layout contains:

```text
~/.local/share/noctalia-local-plugins/liquidctl-control/plugin.toml
```

Add that parent directory as a local plugin source and enable the plugin:

```sh
noctalia msg plugins source add local-hardware path ~/.local/share/noctalia-local-plugins
noctalia msg plugins enable danta/liquidctl-control
```

Then:

1. Open Noctalia Settings → Plugins → Liquidctl Control.
2. Confirm the ASUS Aura pick index. It defaults to `0`, the interface already
   verified for the waterblock.
3. Choose a lighting privilege mode.
4. Open Settings → Bar and add the `Cooling` widget.
5. Click the widget to open the control panel.

For development, point the source at any parent directory that directly
contains the `liquidctl-control` folder.

### Upgrade from 0.1.0 or 0.1.1

Overwrite the existing plugin directory, then disable and re-enable the plugin
to create a fresh controller runtime:

```sh
unzip -o noctalia-liquidctl-control-v0.1.2.zip \
  -d ~/.local/share/noctalia-local-plugins
noctalia msg plugins disable danta/liquidctl-control
noctalia msg plugins enable danta/liquidctl-control
```

## Privileges

Telemetry normally comes from `/sys/class/hwmon` through the `corsair-cpro`
kernel driver and should not require root.

Lighting writes need access to the USB HID devices:

- **Direct** is recommended when liquidctl's udev rules grant your user access.
- **pkexec** asks for authorization through the desktop's polkit agent.
- **sudo -n** never prompts. It only works if you have deliberately configured a
  suitable non-interactive sudo policy.

Do not launch Noctalia itself as root.

## Hardware mapping

| Display name | Commander Pro input |
| --- | --- |
| Coolant | Temperature Probe 1 (configurable) |
| Radiator fan 1 | Fan 1 |
| Radiator fan 2 | Fan 2 |
| Radiator fan 3 | Fan 3 |
| Pump | Fan 4 |

The plugin discovers the Commander Pro hwmon directory dynamically; it does not
hard-code a `hidraw` or `hwmon` number.

## Lighting behavior

| Unified effect | Commander Pro | ASUS Aura |
| --- | --- | --- |
| Static | `fixed` | `static` |
| Pulse / breathing | `color_pulse` | `breathing` |
| Rainbow | `rainbow` | `rainbow` |
| Off | `off` | `off` |

Brightness is applied by scaling the selected RGB value before it is sent.
Commander Pro effects are cleared before a new non-Off effect so repeated panel
use does not exhaust the controller's saved-effect slots.

## Troubleshooting

Validate the plugin against your installed Noctalia build:

```sh
noctalia plugins lint ~/.local/share/noctalia-local-plugins/liquidctl-control
```

If telemetry is unavailable, verify the driver name and sensor files:

```sh
for d in /sys/class/hwmon/hwmon*; do
  printf '%s: ' "$d"
  cat "$d/name" 2>/dev/null
done
```

If a lighting command fails, the panel displays liquidctl's error. Common fixes
are selecting the correct Aura pick index and choosing `pkexec` when direct HID
access is unavailable.
