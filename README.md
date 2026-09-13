# ugreen-dxp480t-plus-thermal

Keep the CPU of a **UGREEN NASync DXP480T Plus** (Intel Core i5-1235U) out of thermal throttling on a third-party OS (tested on Proxmox VE 9), by capping CPU package power and maximum CPU frequency with a small systemd service.

> [!CAUTION]
> **Use at your own risk. No warranty, no liability.**
> Everything in this repository is provided as is. I accept no liability whatsoever for any damage, data loss, hardware failure, voided warranty or anything else that results from using it.
> **Read the code of every script before you run anything on your system.** These scripts run as root and write to kernel interfaces. If you do not understand what a script does, do not run it.
>
> **Nutzung auf eigene Gefahr. Keine Gewährleistung, keine Haftung.**
> Alles in diesem Repository wird ohne jede Gewähr bereitgestellt. Ich übernehme keinerlei Haftung für Schäden, Datenverlust, Hardwaredefekte, Garantieverlust oder sonstige Folgen der Nutzung.
> **Lies den Code jedes Skripts, bevor du irgendetwas auf deinem System ausführst.** Die Skripte laufen als root und schreiben in Kernel-Schnittstellen. Wenn du nicht verstehst, was ein Skript tut, führe es nicht aus.

## The problem

With the firmware defaults the i5-1235U is allowed **25 W sustained (PL1)** and **55 W short-term (PL2)** and runs up to **4.4 GHz** on its P-cores. The DXP480T Plus cooler cannot remove that heat fast enough:

- Any full-load burst hits **98-100 °C within one second** and the CPU throttles for more than half of the time.
- Even at idle, short single-core bursts spike to **95-98 °C**.
- On the test unit the kernel had logged about **38 hours of package throttling in 156 days** of uptime at an average load of 1.5 %.

Fans are not the fix. With the fans forced to 100 % (via the out-of-tree `it87` driver) the CPU still reached 100 °C in the first seconds of load: the bottleneck is heat transfer from the die, not airflow. The NVMe drives were not the problem either (40-53 °C, no thermal management events).

## The fix

`cpu-thermal-limits.sh` sets, at boot and then every 15 minutes:

| Setting | Firmware default | This repo |
|---|---|---|
| Package power PL1 / PL2 | 25 W / 55 W | 15 W / 15 W (Intel's nominal TDP for the i5-1235U) |
| Max frequency per core | 4400 MHz (P) / 3300 MHz (E) | 3000 MHz |

The power cap keeps multi-core load cool. The frequency cap removes the single-core hotspot spikes that a power cap alone does not prevent: one P-core at 4.4 GHz draws about 12 W, under a 15 W cap, but concentrated on a single core.

The trade-off is CPU performance. For a NAS that mostly moves files around this has not been noticeable, but if you run CPU-heavy workloads, measure first and choose your own values.

## Results

All tests on the same unit, 20 s of load, stock BIOS fan control unless noted. Temperatures are the CPU package sensor (`coretemp`), sampled once per second.

**Full load on all 12 threads** (`tests/loadtest.sh`)

| Configuration | Avg temp | Max temp | Avg power | Throttled |
|---|---|---|---|---|
| Firmware defaults | 97.5 °C | 100 °C | 27.2 W | 11.5 s of 20 s |
| Defaults, fans forced to 100 % | 94.4 °C | 100 °C | 29.4 W | 6.1 s |
| 20 W limit (fans ~3000 rpm) | 80.0 °C | 87 °C | 20.2 W | 0.03 s |
| 15 W limit (fans ~3000 rpm) | 70.7 °C | 74 °C | 15.2 W | 0.04 s |
| **15 W + 3000 MHz (after reboot)** | **76.8 °C** | **80 °C** | **15.2 W** | **0 s** |

**Load on one P-core** (`tests/singlecore-test.sh`), 15 W limit

| Max frequency | Avg temp | Max temp | Avg power | Throttled |
|---|---|---|---|---|
| 4400 MHz (default) | 89 °C | 95 °C | 12 W | yes |
| 3500 MHz | 77 °C | 83 °C | 8 W | 0 |
| **3000 MHz** | **70-73 °C** | **76-84 °C** | **6 W** | **0** |
| 2500 MHz | 63 °C | 70 °C | 4 W | 0 |

## Files

```
sbin/cpu-thermal-limits.sh                 apply | reset | status
default/cpu-thermal-limits                 config: POWER_LIMIT_W, MAX_FREQ_MHZ
systemd/cpu-thermal-limits.service         applies limits at boot, "stop" restores defaults
systemd/cpu-thermal-limits.timer           re-applies every 15 min (in case firmware resets them)
systemd/cpu-thermal-limits-reapply.service unit triggered by the timer
tests/loadtest.sh                          full-load test with per-second CSV
tests/singlecore-test.sh                   single-core burst test
```

## Before you install

- **Check your hardware.** The values were measured on a DXP480T Plus with an i5-1235U. On other models or CPUs they may be wrong. Check that `/sys/class/powercap/intel-rapl:0` exists and look at your current values first: `cat /sys/class/powercap/intel-rapl:0/constraint_*_power_limit_uw`.
- **Review what you install.** Clone the repository, look at the exact commit you are about to install and read every file you copy into system directories:

```sh
git clone https://github.com/be-nj/ugreen-dxp480t-plus-thermal.git
cd ugreen-dxp480t-plus-thermal
git log -1                      # note the commit you reviewed
less sbin/cpu-thermal-limits.sh default/cpu-thermal-limits systemd/*
```

Do not pipe anything from the internet straight into a root shell, and do not install a newer commit later without reviewing the changes (`git diff <old>..<new>`).

## Installation

The commands below need root. On a regular Linux system they are shown with `sudo`. On Proxmox VE you are usually logged in as root and `sudo` is not installed: drop the `sudo` prefix there.

```sh
sudo install -o root -g root -m 755 sbin/cpu-thermal-limits.sh /usr/local/sbin/cpu-thermal-limits.sh
sudo install -o root -g root -m 644 default/cpu-thermal-limits /etc/default/cpu-thermal-limits
sudo install -o root -g root -m 644 systemd/cpu-thermal-limits.service systemd/cpu-thermal-limits.timer \
               systemd/cpu-thermal-limits-reapply.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-thermal-limits.service cpu-thermal-limits.timer
sudo cpu-thermal-limits.sh status
```

On the first `apply` the current firmware power limits are saved to `/var/lib/cpu-thermal-limits/`. `reset` (and stopping the service) restores those values and the hardware maximum frequency. So install it while the firmware defaults are still active, not after you have changed the limits some other way.

To change the values, edit `/etc/default/cpu-thermal-limits` and run `sudo systemctl restart cpu-thermal-limits.service`.

### How the config file is handled

The script runs as root, so the config file is treated as untrusted input:

- It is **parsed, not sourced**: only `POWER_LIMIT_W` and `MAX_FREQ_MHZ` are read, and nothing in the file is executed.
- Both values must be integers within sanity bounds: 5-65 W and 800-6000 MHz. Anything else stops the script with an error, and no limits are changed.
- The file must be owned by root and must not be writable by group or others, otherwise the script refuses to run.

Keep it that way: anyone who can write to the files in `/usr/local/sbin`, `/etc/default` or `/etc/systemd/system` can control what runs as root.

## Uninstall

```sh
sudo systemctl disable --now cpu-thermal-limits.timer cpu-thermal-limits.service   # stop restores defaults
sudo rm /etc/systemd/system/cpu-thermal-limits.service /etc/systemd/system/cpu-thermal-limits.timer \
        /etc/systemd/system/cpu-thermal-limits-reapply.service
sudo rm /usr/local/sbin/cpu-thermal-limits.sh /etc/default/cpu-thermal-limits
sudo rm -rf /var/lib/cpu-thermal-limits
sudo systemctl daemon-reload
```

Nothing is written to firmware or NVRAM. The limits live only in the running kernel, so a reboot without the service brings back the firmware defaults.

## Testing

Both test scripts need `stress-ng` (the full-load test also needs `bc`) and must run as root, because they read RAPL energy counters.

```sh
sudo tests/loadtest.sh my-label 20 40        # 20 s load, 40 s cooldown, CSV in $LOADTEST_DIR (default /root/loadtests)
sudo tests/singlecore-test.sh my-label 0     # 20 s load pinned to cpu0
```

Run them before and after installing to see the effect on your own unit.

> [!WARNING]
> These tests put the CPU under full load on purpose. With the firmware defaults the i5-1235U reaches **100 °C** within a second and stays there for the whole test. The CPU protects itself by throttling, but do not make the load longer than necessary, do not run the tests on a machine that already shows cooling problems, and watch the output. Stop a test with `Ctrl+C`.
>
> Load on the host also slows down the VMs and containers running on it.

## Notes on fan control

The DXP480T Plus has an ITE IT8613E Super I/O chip at `0xa30` driving three fans. The mainline `it87` driver does not support it; the fork in [IT-Kuny/UGREEN-DXP-FAN-NAS-Driver](https://github.com/IT-Kuny/UGREEN-DXP-FAN-NAS-Driver) does. Findings from testing it, in case you go that route:

- Once you switch a fan to manual (`pwmN_enable=1`), writing `2` back does **not** restore the BIOS behaviour. The duty register keeps its value, and with the original value the fans stalled at 0-900 rpm. Only a reboot reliably restores the BIOS fan control.
- Above roughly 3000 rpm (PWM ~100) more fan speed made no measurable difference to CPU temperature.

With the limits from this repo, the stock BIOS fan control was sufficient, so the driver is not used here.

## License

MIT, see [LICENSE](LICENSE). The MIT license text includes a full disclaimer of warranty and liability.
