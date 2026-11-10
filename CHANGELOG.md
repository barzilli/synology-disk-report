# Changelog

## 2.3 — 2026-11-10
- **NVMe drives that `smartctl` can't read** (`Read NVMe Identify Controller failed: NVMe Status 0x200b`, seen on an SA3400 with DSM 7.2) are now read with Synology's `synonvme --smart-info-get`, or with `nvme smart-log` if that's missing. The model and serial number come from `/sys` (or `nvme id-ctrl`). Health follows the NVMe rule: PASSED when there's no critical warning. The Notes column says which tool was used.
- "could not read SMART data" now appears only when no health data at all could be read.

## 2.2 — 2026-11-10
- **Long SAS health messages** (such as `DATA CHANNEL IMPENDING FAILURE … [asc=5d, ascq=30]`) no longer break the table. The Health column shows `FAILING` or `WARNING`, and a "Health warnings" list under the table gives each drive's full message, explaining common codes (asc 5D: failure predicted; asc 0B/14: physical element status change).
- The CSV Health column now has the full message, quoted.

## 2.1 — 2026-11-10
- **NVMe drives on a PCIe adapter card** (such as on an SA3600) are now named like Storage Manager, `Cache device <card>-<slot>`, instead of `M.2 Drive N`. A card is recognised by the PCIe switch between the drive and the CPU. Cards are numbered in PCI order, and slots follow DSM's own numbering. Built-in M.2 slots keep `M.2 Drive N`.

## 2.0.1 — 2026-11-10
- Legend and README: on SSDs the Realloc column counts retired NAND flash blocks, not disk sectors.

## 2.0 — 2026-11-10
- **SATA M.2 cache SSDs** (for example on an M2D17 adapter card) now appear in the NVMe / M.2 Cache Drives section instead of the main table. Their wear, written data (when the unit is known), uncorrectable errors, error-log count, unexpected power losses and temperature fill the same columns as NVMe drives, and the Notes column flags heavy wear, reallocated sectors and uncorrectable errors.
- **CSV change:** these drives move from the main CSV to `*_nvme.csv`.
- Adapter-card M.2 slots are named like Storage Manager: `Cache device <card>-<slot>`, for example `Cache device 1-2`.
- With no cache drives, the section now says "No NVMe or M.2 cache drives found."

## 1.9 — 2026-11-10
- New **Life%** column: SATA SSD life remaining, read from the SSD's own wear attribute (231 SSD_Life_Left, 202 Percent_Lifetime_Remain, 169 Remaining_Life_Percentage, 177 Wear_Leveling_Count or 233 Media_Wearout_Indicator). Hard drives show `n/a`.
- CSV gets a matching `SSDLifeRemaining` column, added at the end so existing spreadsheets keep working.
- SSDs outside the main bays are now named `System Drive N`, matching Storage Manager on the HD6500 (was `Internal SSD N`).

## 1.8 — 2026-11-10
- **SAS drives:** power-on hours are now read correctly. The old parser misread the `hours:minutes` format and missed Seagate's `number of hours powered up` line; if neither is in the standard output, the script falls back to `smartctl -x`.
- **SAS drives:** the Uncorr column now shows total uncorrected read, write and verify errors from the error counter log, instead of `n/a`.
- **SATA drives behind a SCSI layer** (such as Synology SAT5210 SSDs on the HD6500), which a plain `smartctl -a` reports as lacking SMART, are now read with `-d sat`, so their hours and health appear.
- **Drives that aren't in Synology's bay list** are no longer given a guessed bay number that could clash with a real bay. SSDs show as `Internal SSD N`, anything else as `Not in bay list`.

## 1.7 — 2026-11-09
- New **NVMe / M.2 cache drives** section: wear level (Used% / Life%), spare capacity, data written, media errors, error-log entries, unsafe shutdowns, temperature and NVMe critical warnings, plus a plain-English Notes column.
- NVMe drives are written to a separate `*_nvme.csv` file when CSV output is on.
- M.2 slot names come from `synodisk --enum -t cache`.
- Added `--help` and `--version`.
- The progress line is shown only on an interactive terminal, so scheduled-task emails stay clean.

## 1.6
- Default parallelism raised to 32 (about 2.6× faster than 8 on a 60-drive system).

## 1.5
- Drives are queried in parallel (`JOBS`), then sorted back into bay order.

## 1.4
- Fixed a blank Slot column.
- The version number is shown in the report header.

## 1.3
- Expansion-unit drives are named by enclosure, for example `RX1217sas-2 Drive 5`.

## 1.2
- Added a Slot column using Storage Manager's bay numbering; rows sorted by bay.

## 1.1
- Drives are found through `/sys/block` and `smartctl --scan` instead of fixed device names.

## 1.0
- First version: make, model, serial, power-on hours, bad-sector counters, SMART health, optional CSV.
