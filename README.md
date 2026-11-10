# synology-disk-report

A single shell script that prints a disk health report for a Synology NAS: one row per drive, in bay order, with the numbers that matter when you're deciding whether a drive needs replacing.

- **Hard drives and SATA SSDs:** make, model, serial number, power-on hours, bad-sector counters (reallocated, pending, uncorrectable), SSD life remaining and the overall SMART health result.
- **NVMe and SATA M.2 cache drives:** wear level (percent of rated endurance used and life remaining), spare capacity, total data written, media errors, error-log entries, unsafe shutdowns, temperature and NVMe critical warnings, with any problems spelled out in plain English.
- **Slot names match Storage Manager:** `Drive 3`, `M.2 Drive 1`, and expansion units by model and number, such as `RX1217sas-2 Drive 5`. M.2 SSDs on a PCIe adapter card (NVMe or SATA) show as `Cache device 1-1` (card 1, slot 1), and SSDs outside the main bays, such as the system SSDs on an HD6500, show as `System Drive N`.
- **Fast on big systems:** drives are queried in parallel, so a 60-drive setup finishes in a few seconds.
- **Optional CSV output** for spreadsheets or tracking trends over time.

Nothing to install: it uses only `bash` and `smartctl`, which are both part of DSM.

## Sample output

```
Disk Report v1.9 - nas01 - 2026-11-09 10:27

Slot                   Device     Make             Model                    Serial                 PowerOnHrs  Realloc  Pending   Uncorr  Life% Health
----                   ------     ----             -----                    ------                 ----------  -------  -------   ------  ----- ------
Drive 1                sas1       Seagate          ST12000NE0007-2GT116     ZXX00001                    75134        0        0        0    n/a PASSED
Drive 2                sas2       Western Digital  WDC WD121KRYZ-01W0RB0    8XX00002                    10935        0        0        0    n/a PASSED
Drive 3                sas3       Seagate          ST12000VN0007-2GS116     ZXX00003                    75158       40        0        0    n/a PASSED
RX1217sas-1 Drive 1    sas16      Seagate          ST12000NE0007-2GT116     ZXX00016                    64815        0        0        0    n/a FAILED!
RX1217sas-1 Drive 2    sas28      Seagate          ST12000VN0007-2GS116     ZXX00028                    75243        0        0        0    n/a PASSED
System Drive 1         sata1      Synology         Synology SAT5210-480G    XXXXXXXXXXX01               34009        ?        ?        ?     99 PASSED

NVMe / M.2 Cache Drives
=======================
Slot           Device    Make            Model                      Serial               PowerOnHrs Used% Life%  Spare%   Written MediaErr  ErrLog  Unsafe  Temp Health   Notes
----           ------    ----            -----                      ------               ---------- ----- -----  ------   ------- --------  ------  ------  ---- ------   -----
M.2 Drive 1    nvme0n1   Synology        SNV3410-400G               XXXXXXXX01                12345     7    93  100/10   50.6 TB        0     112       9    41 PASSED   OK
M.2 Drive 2    nvme1n1   Western Digital WD Red SN700 500GB         XXXXXXXX02                  900    83    17  100/10    512 GB        0       0       0    38 PASSED   over 80% worn - plan replacement
```

(Serial numbers above are made up.)

## Requirements

- Synology DSM 6.x or 7.x
- Root access over SSH, or a Task Scheduler task that runs as `root`
- `bash` 4.3 or later and `smartctl`, both included with DSM

## Installation

1. Download `synology_disk_report.sh` and copy it to a shared folder on the NAS, for example `/volume1/scripts/`, using File Station or `scp`.
2. Enable SSH under **Control Panel → Terminal & SNMP**, then sign in to the NAS over SSH.
3. Make the script executable:
   ```sh
   chmod +x /volume1/scripts/synology_disk_report.sh
   ```

## Usage

```sh
# Print the report
sudo /volume1/scripts/synology_disk_report.sh

# Also save CSV files
sudo /volume1/scripts/synology_disk_report.sh /volume1/scripts/disks.csv
#   -> disks.csv       hard drives
#   -> disks_nvme.csv  NVMe and M.2 cache drives (only written if any are found)

# Change how many drives are queried at once (default 32)
sudo JOBS=8 /volume1/scripts/synology_disk_report.sh

sudo /volume1/scripts/synology_disk_report.sh --help
sudo /volume1/scripts/synology_disk_report.sh --version
```

### Running it on a schedule

Go to **Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script**. On the **General** tab set **User** to `root`. On the **Task Settings** tab, enter for example:

```sh
/volume1/scripts/synology_disk_report.sh /volume1/scripts/disks-$(date +%F).csv
```

Tick **Send run details by email** to have the report emailed to you.

## Reading the report

### Hard drives

| Column | Meaning |
|---|---|
| PowerOnHrs | Total hours the drive has been powered on (8,760 hours = 1 year) |
| Realloc | Hard drives: sectors found bad and replaced with spares (SMART ID 5). SSDs: retired NAND flash blocks (also ID 5); a few are normal, and the drive has thousands of spare blocks. SAS drives: the grown defect list. |
| Pending | Sectors that couldn't be read and are waiting to be remapped (ID 197) |
| Uncorr | Sectors that couldn't be recovered (ID 198); for SAS drives, total uncorrected read + write + verify errors from the error counter log |
| Life% | SATA SSDs only: life remaining as the SSD reports it (attribute 231, 202, 169, 177 or 233, depending on the maker). `n/a` for hard drives. |
| Health | The drive's own overall SMART verdict. SAS drives can report a full sentence here; the table then shows **FAILING** or **WARNING**, and the full message, with a plain-English explanation for common codes, is listed under the table. The CSV always has the full text. |

Plan to replace an SSD when Life% falls below about 10–20%. A drive with a few reallocated sectors that stays stable can keep running for years. A count that **keeps rising**, any **pending or uncorrectable** sectors, or a **FAILED** health result are signs to back up and plan a replacement.

### NVMe / M.2 cache drives

This section lists NVMe drives and SATA M.2 cache SSDs (for example on an M2D17 adapter card). SATA SSDs fill the same columns from their matching SMART attributes; columns that only exist on NVMe drives show `n/a`.

| Column | Meaning |
|---|---|
| Used% | Share of the drive's rated write endurance used up (wear level). It can go past 100%. |
| Life% | 100 − Used% |
| Spare% | NVMe only: spare flash still available / the level at which the drive raises a warning |
| Written | Total data written to the drive. For SATA SSDs it is shown only when the drive states the unit it counts in, since makers count writes differently. |
| MediaErr | Unrecovered data errors (SATA: uncorrectable errors, ID 187 or 198). This should always be 0. |
| ErrLog | Entries in the drive's error log. Often harmless (for example, commands the drive doesn't support), but watch for fast growth. |
| Unsafe | Power losses without a clean shutdown |
| Notes | Problems in plain English: NVMe critical warnings (read-only mode, reliability degraded, etc.), over 80% or 100% worn, low spare capacity, media errors, time spent over the temperature limits |

`?` means the drive doesn't report that value; `n/a` means it doesn't apply to that kind of drive.

## How it works

- **Finding drives:** reads `/sys/block`, falling back to `smartctl --scan` and then to common Synology device names. RAID volumes, the USB boot device and virtual devices are skipped.
- **Slot names:** come from Synology's own `synodisk --enum`. An NVMe drive with a PCIe switch between it and the CPU is on an adapter card; cards are numbered in PCI order and slots in DSM's own order. Expansion units are identified through `/sys/class/enclosure` and the SAS expander chain, and numbered per model in the order they're connected, the same way DSM numbers them. If `synodisk` isn't available, the slot is worked out from the device name, and less certain guesses are marked `(est.)`.
- **Parallel queries:** each drive is read in a background job, up to `JOBS` at a time. Results are then sorted into bay order and any duplicates (the same serial number seen twice) are removed.
- **Read-only:** the script only reads SMART data. It never changes drive settings and never starts a self-test.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `No disks found.` | Run `ls /sys/block` and `smartctl --scan` and open an issue with the output. |
| Slot names don't match Storage Manager | Run `synodisk --enum` (and `synodisk --enum -t cache` for M.2) and open an issue with the output. |
| `could not read SMART data` for an NVMe drive | The DSM build of `smartctl` may be too old to read that drive. Check `smartctl -a -d nvme /dev/nvme0`. |
| Report is slow | Raise `JOBS`, for example `JOBS=32`. |
| Report makes the NAS sluggish while it runs | Lower `JOBS`, for example `JOBS=4`. |

## Tested on

- DSM 7.x, a 12-bay rackmount unit with SAS drives and four daisy-chained RX1217sas expansion units (60 drives in total)
- DSM 7.x, an HD6500 with 60 SAS drives (Seagate Exos) and two Synology SAT5210 SATA SSDs
- An RS4017xs+ with 16 SATA drives and two SATA M.2 cache SSDs on an adapter card
- An FS3017 with 24 Micron SATA SSDs
- An SA3600 with 12 SAS drives, an RX1217sas expansion unit and two NVMe cache SSDs on an adapter card
- The NVMe section and the M.2 slot naming have been tested against simulated `smartctl` output only. Reports from systems with M.2 drives, especially on PCIe adapter cards, are welcome.

## Contributing

Issues and pull requests are welcome, especially output samples from Synology models that aren't listed above. Please replace serial numbers in anything you paste.

### Releases

Releases are automatic. When a commit to `main` changes the `VERSION=` line in `synology_disk_report.sh`, the [Release workflow](.github/workflows/release.yml) creates the `vX.Y` tag and a GitHub Release, using that version's section of `CHANGELOG.md` as the notes and attaching the script. So for a new version: bump `VERSION`, add a `## X.Y` section to the changelog, and push.

## License

[MIT](LICENSE)
