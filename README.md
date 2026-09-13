# ugreen-dxp480t-plus-thermal

Stops the i5-1235U in a **UGREEN NASync DXP480T Plus** from running at 100 °C, by capping CPU power and frequency. Tested on Proxmox VE 9.

> [!CAUTION]
> **Use at your own risk. No warranty, no liability.** Read every script before you run it: they run as root.
>
> **Nutzung auf eigene Gefahr. Keine Gewährleistung, keine Haftung.** Lies jedes Skript, bevor du es ausführst: Sie laufen als root.

## What it does

A systemd service sets two limits at boot and re-applies them every 15 min:

| | Firmware default | This repo |
|---|---|---|
| CPU power (PL1 / PL2) | 25 W / 55 W | **15 W** |
| Max CPU frequency | 4400 MHz | **3000 MHz** |

- **15 W** keeps multi-core load cool.
- **3000 MHz** stops the short spikes when a single core bursts.

The cost is CPU performance. For a NAS that mostly serves and moves files, this has not been noticeable.

The fans are not changed. More fan speed does not help here: even at 100 % fan speed the CPU hit 100 °C.

## Results

Same unit, 20 s of load, BIOS fan control.

| | Before | 15 W + 3000 MHz |
|---|---|---|
| All cores: avg / max | 97.5 °C / 100 °C | **77 °C / 80 °C** |
| One core: avg / max ¹ | 89 °C / 95 °C | **73 °C / 84 °C** |
| Throttled during test | 11.5 s of 20 s | **0 s** |

¹ "Before" measured at 4400 MHz with the 15 W limit already active. A single core draws only about 12 W, so the power limit does not affect this test.

<details>
<summary>All measurements</summary>

**All 12 threads** (`tests/loadtest.sh`)

| Configuration | Avg | Max | Power | Throttled |
|---|---|---|---|---|
| Firmware default | 97.5 °C | 100 °C | 27.2 W | 11.5 s |
| Default, fans at 100 % ² | 94.4 °C | 100 °C | 29.4 W | 6.1 s |
| 20 W, fans ~3000 rpm ² | 80.0 °C | 87 °C | 20.2 W | 0.03 s |
| 15 W, fans ~3000 rpm ² | 70.7 °C | 74 °C | 15.2 W | 0.04 s |
| 15 W + 3000 MHz | 76.8 °C | 80 °C | 15.2 W | 0 s |

**One P-core**, 15 W limit (`tests/singlecore-test.sh`)

| Max frequency | Avg | Max | Power | Throttled |
|---|---|---|---|---|
| 4400 MHz | 89 °C | 95 °C | 12 W | yes |
| 3500 MHz | 77 °C | 83 °C | 8 W | 0 |
| 3000 MHz | 70-73 °C | 76-84 °C | 6 W | 0 |
| 2500 MHz | 63 °C | 70 °C | 4 W | 0 |

² Fans set to a fixed speed with the temporary `it87` driver, see [Fans](#fans).

</details>

## Requirements

- Intel CPU with RAPL (`/sys/class/powercap/intel-rapl:0` exists)
- systemd, bash
- Tests only: `stress-ng`

**No extra driver or DKMS needed.** Everything uses standard kernel interfaces.

## Install

Commands use `sudo`. On Proxmox you are usually root already: leave out `sudo`.

**1. Get the code and read it**

```sh
git clone https://github.com/be-nj/ugreen-dxp480t-plus-thermal.git
cd ugreen-dxp480t-plus-thermal
less sbin/cpu-thermal-limits.sh default/cpu-thermal-limits systemd/*
```

**2. Install**

```sh
sudo install -o root -g root -m 755 sbin/cpu-thermal-limits.sh /usr/local/sbin/
sudo install -o root -g root -m 644 default/cpu-thermal-limits /etc/default/
sudo install -o root -g root -m 644 systemd/cpu-thermal-limits.service systemd/cpu-thermal-limits.timer \
        systemd/cpu-thermal-limits-reapply.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-thermal-limits.service cpu-thermal-limits.timer
```

**3. Check**

```sh
sudo /usr/local/sbin/cpu-thermal-limits.sh status
```

On every boot the service first saves the current firmware values to `/run/cpu-thermal-limits`, then applies the limits. `reset` restores the saved values.

## Configure

Edit `/etc/default/cpu-thermal-limits`:

```sh
POWER_LIMIT_W=15     # 5-65, empty = leave unchanged
MAX_FREQ_MHZ=3000    # 800-6000, empty = leave unchanged
```

Then check and apply it:

```sh
sudo /usr/local/sbin/cpu-thermal-limits.sh check
sudo systemctl reload cpu-thermal-limits.service
```

Use `reload`, not `restart`. A reload with an invalid config fails and keeps the current limits. A restart resets to the firmware values first.

For safety the file is parsed, never executed. It must be owned by root and not writable by anyone else. The systemd units also restrict the script: no network, no capabilities, and a read-only system except the power limit and cpufreq settings in `/sys`.

## Update

Read the changes first (`git pull`, then `git log -p`). Then install the script and units again, without the config line, so your settings are kept:

```sh
sudo install -o root -g root -m 755 sbin/cpu-thermal-limits.sh /usr/local/sbin/
sudo install -o root -g root -m 644 systemd/cpu-thermal-limits.service systemd/cpu-thermal-limits.timer \
        systemd/cpu-thermal-limits-reapply.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart cpu-thermal-limits.service cpu-thermal-limits.timer
```

## Undo

```sh
sudo systemctl disable --now cpu-thermal-limits.timer cpu-thermal-limits.service
sudo rm /usr/local/sbin/cpu-thermal-limits.sh /etc/default/cpu-thermal-limits \
        /etc/systemd/system/cpu-thermal-limits.service /etc/systemd/system/cpu-thermal-limits.timer \
        /etc/systemd/system/cpu-thermal-limits-reapply.service
sudo rm -rf /run/cpu-thermal-limits
sudo systemctl daemon-reload
```

Stopping the service restores the firmware values right away. During shutdown the limits are kept on purpose, so running VMs can shut down without overheating. Nothing is written to firmware: a boot without the service always starts with the firmware values.

## Test on your own unit

```sh
sudo tests/loadtest.sh before 20 40       # all cores: 20 s load, 40 s cooldown, CSV in /root/loadtests
sudo tests/singlecore-test.sh before 0    # one core (cpu0) for 20 s
```

> [!WARNING]
> The tests heat the CPU on purpose. With the firmware defaults it reaches 100 °C. Keep the tests short, and stop them with `Ctrl+C`. VMs on the host slow down during a test.

## Fans

Background only, **not needed for this fix.**

- The fans are driven by an ITE IT8613E chip. Linux can only control it with a third-party, out-of-tree driver ([IT-Kuny/UGREEN-DXP-FAN-NAS-Driver](https://github.com/IT-Kuny/UGREEN-DXP-FAN-NAS-Driver)).
- That driver was used here only for the fan measurements and removed afterwards. It is not part of this repo and not reviewed by it.
- Pitfall: after switching the fans to manual, writing `pwmN_enable=2` does **not** bring back BIOS fan control. The fans stalled. Only a reboot restored it.
- Above ~3000 rpm, more fan speed made no difference to CPU temperature.

## License

[MIT](LICENSE), provided as is, without warranty.
