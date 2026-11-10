# Changelog

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
