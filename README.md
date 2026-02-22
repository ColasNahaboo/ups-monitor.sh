# ups-monitor.sh

A robust Linux Bash script designed for **NUT (Network UPS Tools)** to manage staged shutdowns during power outages. It is specifically optimized for Eaton UPS units (supporting `TRIM/AVR` status) but works with any UPS supported by NUT. It is aimed at a home hobbyist network with more than one machine on the same UPS that can be shut down via ssh from the linux server connected to the UPS via USB.

Only tested on Debian and Ubuntu with an USB-connected Eaton 5SC UPS.

## Features

- **Staged Shutdown Logic**:
  
  - **90% Battery**: Shuts down non-critical "First" servers (e.g., storage, backups).
  
  - **80% Battery**: Shuts down "Extra" servers.
  
  - **20% Battery**: Shuts down the monitoring host and places the UPS in standby to conserve battery while ensuring it automatically wakes up when power returns.

- **Configuration File**: Change these (and more) in the optional `/etc/ups-monitor.conf` to override settings without modifying the main script.

- **AVR Tracking**: Special handling for `TRIM` (overvoltage) and `BOOST` (undervoltage) events, logging the exact input voltage during these fluctuations.

- **Email Alerts**: Sends notifications for power loss, staged shutdowns, and power restoration. Logs everything in `/var/log/ups-monitor/`

- **Dry-Run Mode**: If `/tmp/NOUPSMON` exists, the script logs actions but does not actually send shutdown commands or kill power.

- **Log Management**: Automatically rotates logs monthly and includes a `clean` command to prune old history.

My UPS provides power to some servers/NAS and main switch and wifi access point. This script allows to shutdown early the non-essential devices, and keep the main server live and wifi access to it (by ssh apps on phones and tablets) as long as possible.

![diagram of a typical setup](doc/diagram.png)

## Prerequisites

- **A linux server**. The installation steps describe how to run the script via `systemd`, but you can choose to just run it via any means you want.

- **The Network UPS Tools (NUT)** package (`upsc` and `upscmd` utilities installed).

- **Mail** configured for outgoing alerts.

- **SSH Key Access**: The monitoring host must have passwordless SSH access from the local root account under which the script runs to the remote servers it needs to shut down.

- **Security caveat**: Not suitable for high-security environments. This script requires root execution, stores the UPS password in plain text, and relies on passwordless SSH keys to manage remote servers. It is ideal for protected home networks but should be avoided in enterprise settings where "bad actor" access is a concern.

- **Hardware**: Of course, an **UPS power supply unit**, connected to the server via usb. I chose an Eaton 5SC 100i, but it should work with most brands and models.

**Warning**: I advise strongly to chose a "**pure sine wave**" UPS. Otherwise, when switching to batteries, your computer power supply (the ones with "Active PFC") may not like the "squarish" wave shape of the voltage coming out of the UPS, and decide to shut down abruptly in panic. E.g, do not buy the "Ellipse" line of Eaton UPS. The Eaton 5SC was the cheapest nice "pure sine wave" gear I could find around me, but many others fit the bill. In real life, power supplies will not have this problem, but buying a "pure sine wave" UPS eliminates the guessing... but is 3 times the price of a simulated sine wave UPS (but still better in my opinion than having to replace a drive or motherboard). Your choice.

**Tip**: do not hesitate to chat with your favorite AI to help you on these subjects if you feel lost. Chatting with Gemini was very helpful for me, a UPS-novice, in coding this script, by asking for context, vocabulary, explanations, debug, testing, and toying with "what if" scenarios, even if it did not actually write the code or the doc of this script.

## Installation

1. install nut
   ```bash
   sudo apt install nut
   ```
2. copy the script into your path, e.g. `/usr/local/bin`
   ```bash
   cp ups-monitor.sh /usr/local/bin/ups-monitor.sh
   ```
3. Setup Systemd Service:
   Create `/etc/systemd/system/ups-logic.service` containing:
   ```TOML
   [Unit]
   Description=UPS Monitoring and Staged Shutdown Logic
   After=nut-server.service
   
   [Service]
   ExecStart=/usr/local/bin/ups-monitor.sh
   Restart=always
   User=root
   
   [Install]
   WantedBy=multi-user.target
   ```
4. Setup your local **configuration**:
   create and edit `/etc/ups-monitor.conf` to customize your setup. You can use the provided `ups-monitor-sample.conf` as a guide, and also see the Configuration section below.
5. Enable and start:
   ```bash
   sudo systemctl enable --now ups-logic.service
   ```
6. Setup Daily Cleanup:
   Add this to your root crontab (`sudo crontab -e`) to delete logs in `/var/log/ups-monitor/` older than a year and keep a copy of the UPS complete state at the beginning of the day for reference:
   ```bash
   01 00 * * * /usr/local/bin/ups-monitor.sh clean
   ```
   
### Configuration
  
   `/etc/ups-monitor.conf` is a bash script that will be executed (sourced) by the script on startup, so you can there redefine any bash variable and functions definitions occuring in the script before the comment `END OF CONFIGURATION`

You can redefine the battery levels at which you trigger the shutdown of the first and xtra servers, and the names of these servers.

Note that you can also redefine the functions. For instance, you could redefine `remoteshut` to execute an action other than a mere shutdown via ssh, for instance if you must shutdown a NAS with a call to its API via `curl`, or a Windows machine with a specific protocol.
Or redefine `info` to warn the admin other than by email: a phone message, a sound alarm, ...

### Upgrade

If a new version is published, just:

```bash
# download and copy the new ups-monitor.sh
cp ups-monitor.sh /usr/local/bin/ups-monitor.sh
# restart the service
sudo systemctl restart ups-logic.service
```

And of course check the Release Notes at the end of this README to check if any manual action is required for the upgrade.

## Logging

The script maintains two types of logs in `/var/log/ups-monitor/`:

- `YYYY-MM.log`: A chronological history of every status change and action taken.
- `last.status`: A snapshot of the full UPS status output the last time an alert was triggered.

## Testing

To test your logic without actually shutting down your infrastructure, with the servioce running:

1. Run `touch /tmp/NOUPSMON`. Creating this file will dynamically switch the script in "dry run" mode without the need to restart it.
2. Unplug your UPS.
3. Monitor the logs: `tail -f /var/log/ups-monitor/$(date +%Y-%m).log`.
4. Once satisfied, `rm /tmp/NOUPSMON`. No need to restart the service.

## License

MIT License - (c) 2026 Colas Nahaboo.
In a nutshell: do whatever you want with this, and please credit me, but expect no warranty.

## Release Notes

- v1.0.0 2026-02-22 First public release
