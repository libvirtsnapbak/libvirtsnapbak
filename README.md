# LibvirtSnapBak
LibvirtSnapBak is a scripted differential backup system for LibVirt/QEMU virtual machine storage devices.
It creates point-in-time differential disk backups in a user-specified backup directory.
## Installation
### Prerequisites
* bash     >= 4.3.0
* qemu_img >= 1.2.0
* qemu     >= 1.2.0
* rsync    >= 2.6.0
* virsh    >= 0.9.13

To backup a running virtual machine, `qemu-guest-agent` must be installed and running on the guest operating system.

On some Linux distributions, the default LibVirt Apparmor profiles may need to be reconfigured / disabled to allow full functionality (see [Permissions](https://github.com/libvirtsnapbak/libvirtsnapbak/edit/main/README.md#permissions) below).

### Clone
```bash
git clone https://github.com/libvirtsnapbak/libvirtsnapbak.git
```
## Usage
```bash
sudo /path/to/libvirtsnapbak.sh [OPTIONS]
```
```
Options:
--help, -h                    Print usage and exit
--version, -v                 Print version and exit
--backup-dir, -b=<dir>        Backup to the specified <dir> [Required]
--mode, -m=<mode>             Backup in specified <mode> [Required]
                             <diff>:
                             - Backup current differential snapshot (start new if none)
                             - Retain previous differential snapshot(s) in 'DiffHistory' dir
                             <copy>:
                             - Backup current differential snapshot & base file(s) in 'Copy' dir
                             - Rebase all linkages (full standalone backup)
                             <consolidate>:
                             - Consolidate current differential snapshot into base
                             - Backup base file(s)
                             - Start new differential snapshot
                             <archive>:
                             - Consolidate current differential snapshot into base
                             - Backup base file(s) in 'Archive' dir
                             - Rebase all linkages (full standalone backup)
                             - Stop differential
                             <stop>:
                             - Consolidate existing differential snapshot into base
                             - Stop differential
--all, -a                     Backup all domains [Overrides --non-running, --domain]
--non-running, -n             Backup all non-running domains [Overrides --domain]
--domain, -d=<domain name>    Backup specified <domain name> [Required unless --all or --non-running]
--exclude, -e=<domain name>   Exclude specified <domain name>
--prune, -p=<max number>      Prune 'DiffHistory' dir:
                             - Retain <max number> most recent differential snapshots
--debug, -D                   Debug
--verbose, -V                 Verbose
```
## Features
* Differential backup of all storage devices for one (or more, or all) virtual machines (a.k.a. domains)
* Exclude one or more virtual machines
* Retain differential backup history, enabling point-in-time restore
* Prune backup directory to limit differential backup history retention
* Optionally create a full standalone backup, enabling independent access / restore
* Works on both running and non-running virtual machines
## Permissions
### Root permissions
By default, LibVirt and QEMU services run as root - consequently, certain operations on storage pools and snapshots must also be performed as root.
Therefore, the simplest usage of LibvirtSnapBak is to always run it as root (using sudo) - this will ensure that it can always access storage files and operate on snapshots as needed.
Alternatively, the LibVirt and Qemu services can be reconfigured to run as non-root user accounts, which will circumvent the need for sudo with LibVirtSnapBak, but this is not recommended.
### LibVirt AppArmor bug
In some linux distributions (e.g. Debian, Ubuntu), the default LibVirt AppArmor profiles prevent the creation / deletion of external snapshots. (This is a bug in LibVirt - see this [bug report](https://gitlab.com/libvirt/libvirt/-/issues/622) for more information).  

For a quick fix, simply edit `/etc/libvirt/qemu.conf` and set `security_driver = "none"`.
## Modes
* **Diff** mode:  
  - In 'diff' mode, LibvirtSnapBak uses LibVirt's built-in snapshot mechanism to operate with a 'base' and a 'diff'.
  - The 'base' is frozen - all subsequent disk writes are captured in a persistent 'diff' (the 'SnapBakDiff' snapshot).
  - The source folder hierarchy of each storage device will be recreated within the backup directory, with a further 'DiffHistory' sub-directory for the retention of previous diffs.
  - On the first run in this mode, LibvirtSnapBak will backup the 'base' and create a 'SnapBakdiff' snapshot.
  - On each subsequent run in this mode, LibvirtSnapBak will only backup the 'diff' if it detects that disk writes have been made since the last run.
  - It will retain a history of previous 'diff' backups (with timestamps) in the 'DiffHistory' sub-directory, the maximum number of which can be controlled using the `--prune/-p` option.
* **Copy** mode:
  - In 'copy' mode, LibvirtSnapBak will create a full independant backup of both the 'base' and the 'diff' in a timestamped 'Copy' backup sub-directory.
  - It will rebase any snapshots so that they point to their corresponding base (a.k.a. backing) file in the backup directory, rather than their base file in the original source location.
* **Consolidate** mode:
  - In 'consolidate' mode, LibvirtSnapBak will merge an existing 'diff' snapshot into the 'base' and create a new 'diff'.
  - Any changes captured to date within the 'diff' will thus be made permanent in the 'base'.
  - Also, any 'diffs' in the 'DiffHistory' folder will thus be orphaned as the 'base' has now permanently changed.
  - LibvirtSnapBak will backup the new 'base' and cleanup the 'DiffHistory' sub-directory.
  - Use this mode to reduce the size of the persistent 'diff' snapshot, and clean out the 'DiffHistory' sub-directory, if they grow too large.
* **Archive** mode:
  - In 'archive' mode, LibvirtSnapBak will merge an existing 'diff' snapshot into the 'base' _WITHOUT_ creating a new 'diff'.
  - Any existing 'diff' backups will thus be orphaned (as per consolidate mode above).
  - LibvirtSnapBak will create a full backup of the new 'base' in a timestamped 'Archive' backup sub-directory.
  - It will rebase any snapshots so that they point to their corresponding base (a.k.a. backing) file in the backup directory, rather than their base file in the original source location.
* **Stop** mode:
  - In 'stop' mode, LibvirtSnapBak will merge an existing 'diff' snapshot into the 'base' _WITHOUT_ creating a new 'diff'.
  - Any existing 'diff' backups will thus be orphaned (as per consolidate mode above).
## Restore
* To restore a backup, simply replace the SnapBakDiff snapshot file in the original source location with the copy from the backup location.
* To restore to an earlier point-in-time, simply remove the timestamp from the SnapBakDiff snapshot filename before copying and replacing.
* To access a standalone copy or archive, either attach the backup (in-place) to a virtual machine (read-only recommended), or mount via nbd or loop device.
## Logging
LibVirtSnapBak has `--verbose/-V` and `--debug/-D` output options to assist in the resolution of any errors.
In addition, a detailed timestamped log file is created on each run in: `/path/to/your-backup-dir/_logs`
## Manual External Snapshots
LibvirtSnapBak will detect the presence of manual external snapshots on a virtual machine and adjust operations accordingly:
* It will not create a diff snapshot on top of an existing manual snapshot.
* If a manual external snapshot has been created on top of an existing SnapBakDiff snapshot, then it will leave the SnapBakDiff untouched in order to preserve the integrity of the snapshot chain.
* It will still backup storage devices (including manual snapshots) if disk writes have been made since the last run (essentially treating the manual snapshot as a 'diff' in itself).
* Once the manual external snapshot has been merged, or reverted and deleted, then LibvirtSnapBak operations will continue as normal on the existing 'base' (or existing 'diff', if any).
## Examples
1. To backup 2 virtual machines in 'diff' mode (retaining a maxmum of 28 differential backups in the 'DiffHistory' backup sub-directory):
   
    ```bash
    sudo ./path/to/libvirtsnapbak.sh -b=/path/to/your-backup-dir -m=diff -d=your-domain0 -d=your-domain1 -p=28
    ```
2. To backup all virtual machines in 'copy' mode, excluding 'your-domain2':
   
    ```bash
    sudo ./path/to/libvirtsnapbak.sh -b=/path/to/your-backup-dir -m=copy -a -e=your-domain2
    ```
3. To consolidate an existing differential into the base image on 'your-domain3':
   
    ```bash
    sudo ./path/to/libvirtsnapbak.sh -b=/path/to/your-backup-dir -m=consolidate -d=your-domain3
    ```
4. To backup (and consolidate) all virtual machines in 'archive' mode, excluding 'your-domain4':  

    ```bash
    sudo ./path/to/libvirtsnapbak.sh -b=/path/to/your-backup-dir -m=archive -a -e=your-domain4
    ```
5. To stop (and consolidate) an existing differential on 'your-domain5':  
    ```
    sudo ./path/to/libvirtsnapbak.sh -b=/path/to/your-backup-dir -m=stop -d=your-domain5
    ```
## Scheduled backups
To run LibvirtSnapBak on a schedule, simply add a job via the sudo crontab.  

For example, to schedule a run in diff mode on all domains (with pruning) every 4 hours:  
* Edit the sudo crontab:
  
    ```bash
    sudo crontab -e
    ```
* Append the LibvirtSnapBak cron timings, command, and options (no output logging needed, as LibvirtSnapBak creates its own logs):
  
    ```bash
    0 */4 * * * /path/to/libvirtsnapbak.sh -b=/path/to/your-backup-dir -m=diff -a -p=28 >> /dev/null 2>&1
    ```
* Check the sudo crontab:
  
    ```bash
    sudo crobtab -l
    ```
## Copyright
Copyright (C) 2025 Jeff Pollard - <libvirtsnapbak@outlook.com>  

This file is part of LibvirtSnapBak, licensed under the GNU AGPLv3.  

See LICENSE file for further details.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

## Acknowledgements
LibvirtSnapBak is a divergent fork of fi-backup by Davide Guerri.
