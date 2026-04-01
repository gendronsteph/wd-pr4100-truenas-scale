# WD PR4100 / PR2100 TrueNAS SCALE Front Panel Scripts

Front panel control scripts for the **Western Digital PR4100 / PR2100** running **TrueNAS SCALE**.

These scripts control the NAS front panel features through the PMC controller, including:

- LCD display
- front LEDs
- fan control
- button handling
- status pages for system information

They were adapted and tested on a **WD PR4100 with TrueNAS SCALE**, and are intended for users with a very similar hardware and software setup.

---

## Features

### Front panel / hardware control
- LCD backlight control
- front LED control
- fan speed control
- button support (Up / Down / USB, depending on hardware behavior)

### LCD status pages
- TrueNAS / IP address
- pool name / pool health
- pool usage and status
- CPU temperature
- fan percentage / RPM
- hottest disk temperature
- internal disk summary
- live network throughput (RX / TX)
- live physical disk throughput (Disk Read / Disk Write)
- uptime
- RAM usage
- ZFS ARC usage

### Runtime behavior
- automatic screen rotation
- manual navigation with front buttons
- automatic transfer screen when activity is detected
- automatic return to rotation mode after button inactivity
- basic alert display for:
  - high CPU temperature
  - high disk temperature
  - high PMC temperature
  - low fan RPM
  - degraded / unhealthy pool state

---

## Compatibility

These scripts are intended for:

- **WD PR4100**
- **WD PR2100**
- **TrueNAS SCALE**

They rely on the front panel PMC being reachable through a serial device such as:

- `/dev/ttyS2`
- sometimes another `/dev/ttyS*` device on some systems

The scripts in this version were validated on a setup where the PMC was reachable on:

- `/dev/ttyS2`

---

## Important Notes

These scripts are **not universal** for all NAS systems.

They are designed for WD PR-series hardware with a compatible front panel controller.  
They may work for another user with the same hardware and a similar TrueNAS SCALE setup, but some adjustments may still be required depending on:

- serial device mapping
- disk layout
- USB devices connected
- button behavior
- boot / shutdown behavior on the specific machine

Use at your own risk.

---

## Files

- `pr4100-common.sh`  
  Shared helper functions for PMC communication, LCD, LEDs, fan control, disk and system metrics.

- `wdpreinit-v2.sh`  
  Pre-init script. Sets a basic startup state early in boot.

- `wdpostinit-v2.sh`  
  Main runtime script. Handles LCD pages, metrics, fan logic, alerts, and buttons.

- `wdshutdown-v2.sh`  
  Shutdown script. Displays shutdown/reboot message and updates LED/fan state before exit.

---

## Requirements

The following tools should be available on the system:

- `bash`
- `awk`
- `sed`
- `grep`
- `cut`
- `tr`
- `sort`
- `head`
- `tail`
- `find`
- `readlink`
- `lsblk`
- `flock`
- `ip`
- `hostname`
- `smartctl`
- `sensors`
- `zpool`

On TrueNAS SCALE, most of these are typically already available, but `smartctl` and `sensors` support still depends on the environment and hardware support.

---

## Installation

### Option 1: Install via Git

SSH into your TrueNAS SCALE system and become root:

```bash
sudo -i
```

Choose a location for the scripts, then clone the repository:

```bash
mkdir -p /root
cd /root
git clone https://github.com/gendronsteph/wd-pr4100-truenas-scale.git wd-pr4100
cd /root/wd-pr4100
```

Make the scripts executable:

```bash
chmod +x pr4100-common.sh
chmod +x wdpreinit-v2.sh
chmod +x wdpostinit-v2.sh
chmod +x wdshutdown-v2.sh
```

### Option 2: Manual install

SSH into your TrueNAS SCALE system and become root:

```bash
sudo -i
```

Create a directory for the scripts:

```bash
mkdir -p /root/wd-pr4100
cd /root/wd-pr4100
```

Copy the script files into that directory, then make them executable:

```bash
chmod +x pr4100-common.sh
chmod +x wdpreinit-v2.sh
chmod +x wdpostinit-v2.sh
chmod +x wdshutdown-v2.sh
```

---

## Add the scripts in the TrueNAS web UI

Go to:

**System Settings -> Advanced -> Init/Shutdown Scripts**

Add the scripts as follows.

### Pre Init

- **Description:** WD PR4100 Pre Init
- **Type:** Script
- **Script:** full path to `wdpreinit-v2.sh`  
  Example: `/root/wd-pr4100/wdpreinit-v2.sh`
- **When:** Pre Init
- **Enabled:** Yes
- **Timeout:** 10

### Post Init

- **Description:** WD PR4100 Post Init
- **Type:** Script
- **Script:** full path to `wdpostinit-v2.sh`  
  Example: `/root/wd-pr4100/wdpostinit-v2.sh`
- **When:** Post Init
- **Enabled:** Yes
- **Timeout:** 10

### Shutdown

- **Description:** WD PR4100 Shutdown
- **Type:** Script
- **Script:** full path to `wdshutdown-v2.sh`  
  Example: `/root/wd-pr4100/wdshutdown-v2.sh`
- **When:** Shutdown
- **Enabled:** Yes
- **Timeout:** 10

---

## Notes

Main runtime logs are written to:

```bash
/tmp/pr4100-hw/pr4100.log
```

---

## Current Behavior

### Automatic LCD pages

The main script rotates through several pages, including:

- TrueNAS / IP
- pool health
- pool usage / free space / activity
- CPU / PMC
- fan / RPM
- hottest disk
- disk summary
- RX / TX throughput
- physical disk read / write throughput
- uptime
- RAM / ARC

### Transfer activity

When active transfer is detected, the script can temporarily prioritize live activity screens.

### Fan behavior

A simple fan profile is applied based on:

- CPU temperature
- hottest internal disk temperature
- PMC temperature
- alert conditions

---

## Limitations

- Button handling may vary depending on firmware / PMC behavior.
- Some values may not be available on every setup:
  - PMC temperature
  - fan RPM
  - certain SMART temperature formats
- Network throughput reflects interface traffic, not protocol-specific usage.
- Disk read/write activity reflects physical internal disk IO, not necessarily what ZFS reports in RAM/cache at that exact moment.
- Shutdown / reboot behavior may still depend on TrueNAS SCALE, systemd, hardware state, or storage state.

---

## Safety / Disclaimer

These scripts directly interact with hardware-related functions such as:

- front panel controller
- fan speed
- LEDs
- shutdown display state

Use them at your own risk.

Always test carefully after changes, especially:

- fan logic
- shutdown behavior
- button behavior
- disk detection

---

## Credits

This work is based on community efforts around WD PR-series hardware support, including:

- [@stefaang](https://gist.github.com/stefaang/0a23a25460f65086cbec0db526e87b03)
- [@Coltonton](https://github.com/Coltonton/WD-PR4100-FreeNAS-Control)

This version was further adapted for a TrueNAS SCALE setup with improved LCD pages, metrics, fan behavior, and front panel handling.

---

## Status

This version is intended as a practical working version, not as a polished product.

It is usable, customizable, and much closer to a day-to-day working setup than the original “dead / broken / never finished” warning suggested, but it is still a community script set and should be treated accordingly.
