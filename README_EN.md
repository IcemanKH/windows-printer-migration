[中文](README.md) | English

# 🖨️ Minimal Printer Driver Backup & Restore for Windows

> Two BAT files and one PowerShell script to move your printers and their drivers from an old PC to a new one.
> **Tiny, simple, nothing to install.**

`v1.0.0` ｜ Windows 10 / 11 ｜ PowerShell 5.1+

---

## ✨ Why use it

- **Tiny** — just 3 files, copy them anywhere and run
- **Zero dependencies** — Windows built-in components only, no third-party software
- **Simple** — double-click a BAT, pick your printers, back them up; copy to the new PC, double-click, restore
- **Self-contained restore** — the backup folder automatically carries its own restore launcher and core script
- **Strict validation** — driver identity + SHA256 + digital signature; anything that fails is not installed
- **Deliberately cautious** — no `Bypass`, no `/force`, no system policy changes, never overwrites existing printers
- **Clear verdicts** — every printer is labelled *Complete backup* / *Partial backup* / *Not migratable*

---

## 🎯 Who it's for

- Setting up a new starter's PC with the printers they need
- Restoring printers after a clean Windows reinstall
- Moving printers when you switch to a new computer
- Restoring from a USB drive when the new PC has no usable network

---

## 📁 Files

Put these **3 files in the same folder**:

| File | Purpose |
| --- | --- |
| `01_备份打印机.bat` | Run on the **old** PC |
| `02_恢复打印机.bat` | Run on the **new** PC |
| `Printer_Migration.ps1` | Core script, invoked by both BAT files |

> ⚠️ All three files must sit in the same folder. Each BAT checks that the core script is next to it and exits with an error if it is missing.

When the backup entry is launched, it first prints the banner, the program folder and the backup output folder:

![Backup entry screen](docs/images/backup-entry.png)

> Every screenshot here uses **demo data** — sample printer names, a sample computer name and RFC5737 documentation IPs. None of it comes from a real environment.

---

## 🚀 Three steps

### 1️⃣ Old PC: back up

Double-click `01_备份打印机.bat` → accept the UAC prompt → choose which printers to back up:

```text
2          # one printer
1,3,5      # several (comma- or space-separated)
1-3        # a range
all        # everything
```

![Selecting printers to back up](docs/images/backup-select.png)

When it finishes, a `Printer_Backup/` folder is created next to the script:

```text
Printer_Backup/
├── 02_恢复打印机.bat      ← copied in automatically; the restore entry for the new PC
├── Printer_Migration.ps1  ← copied in automatically; the core script
├── Printers.json          ← backup manifest
├── 配置清单.txt            ← human-readable summary
├── 恢复说明.txt            ← restore instructions shipped with the folder
├── Checksums.json         ← SHA256 checksum manifest
├── 校验清单.txt            ← SHA256 checksum manifest (human-readable)
├── Drivers/               ← exported driver packages
└── Logs/
```

Each printer gets a three-level verdict, summarised at the end:

![Backup result summary](docs/images/backup-result.png)

### 2️⃣ Move it across

Copy the **whole** `Printer_Backup` folder to a USB stick or external drive, then copy it to a local disk on the new PC (for example, the Desktop).

> Copy the entire folder, not a handful of files — and don't run the restore directly from the USB drive or a network share.

![Backup folder structure](docs/images/backup-folder.png)

### 3️⃣ New PC: restore

Double-click `Printer_Backup\02_恢复打印机.bat` → accept the UAC prompt → follow the prompts:

- **Driver package available** → installs the driver and recreates the port and print queue
- **Network printer with an IP** → shows the port plan, then creates it and checks connectivity once you confirm
- **USB printer** → asks you to plug it in and power it on, then detects it
- **Not enough information** → prints the manual steps instead

Before touching anything, it locates the backup automatically, verifies the SHA256 checksums and checks architecture compatibility and signatures:

![Restore entry and integrity checks](docs/images/restore-entry.png)

Afterwards you can optionally print a test page and review the summary: **Restored / Driver installed / Needs manual steps**.

![Restore result summary](docs/images/restore-result.png)

---

## 🧩 Backup verdicts

| Verdict | Meaning |
| --- | --- |
| ✅ **Complete backup** | The driver was exported and passed identity, integrity and signature checks — it can be installed automatically |
| ⚠️ **Partial backup** | A driver file is missing, or one manual step is needed (shared printers, network printers with no IP, USB printers that need replugging) |
| ❌ **Not migratable** | The old driver has no exportable INF — install the vendor's driver package on the new PC |

> The overall result is **Success** only when every selected printer is a complete backup.

---

## 🛠️ Requirements

- Windows 10 / 11 (x86, x64 or ARM64)
- Windows PowerShell 5.1 (ships with Windows)
- Administrator rights — the script requests UAC elevation automatically
- Everything it uses ships with Windows: `pnputil`, the `PrintManagement` module, `printui.dll` and so on

---

## 🔐 Permissions and execution policy

- Backup and restore both need administrator rights; if the UAC prompt is dismissed, right-click the BAT and choose **Run as administrator**
- It **never** uses `-ExecutionPolicy Bypass` and **never** changes system policy
- Only when the policy is the Windows default does it add `RemoteSigned` for the current process; Group Policy always wins
- If the script is "blocked": right-click `Printer_Migration.ps1` → Properties → tick **Unblock**

---

## ❓ Troubleshooting

| Symptom | What to do |
| --- | --- |
| `Printer_Migration.ps1 was not found` | The three files aren't in the same folder |
| `running scripts is disabled` | Execution policy is blocking it — see the section above, or ask IT to allow it |
| `Printers.json was not found` | The backup folder wasn't copied in full |
| Checksum mismatch | The backup is corrupt and the installer refuses to continue — back up again from the old PC |
| Network printer not responding | It's powered off or on a different network; you can create the queue first and confirm later |
| Shared printer not restored | Shared printers need network and account access, so they are never connected automatically — add them by hand |
| "Not migratable" reported | Install the vendor's driver package on the new PC |
| USB printer not detected | Plug it in and power it on, wait for a port such as `USB001`, then run the restore again |
| Test page didn't print | The tool can only queue the job — check the printer's power, paper and queue |
| Default printer changed | The tool tries to restore it and warns you if Windows overrode it; you can set it manually |

---

## ⚠️ Known limitations

1. Only drivers that can be exported as an INF from the Windows driver store can be restored automatically
2. Vendor installers are not exported; drivers without an INF are marked as not migratable
3. Cross-architecture restore is not supported (32↔64 and x64↔ARM64 drivers usually can't be installed)
4. Shared printers are never connected automatically
5. Network printers need a valid IP; WSD ports have to be rediscovered on the new PC
6. Existing printers with the same name are never overwritten
7. Nothing is deleted, the default printer is not changed, and the PC is never rebooted
8. `/force` is never used — a failed signature check means the driver is not installed
9. Only the printers you select are processed; the driver store is never exported wholesale

---

## 🧪 Self-test

```bat
01_备份打印机.bat -SelfTest
02_恢复打印机.bat -SelfTest
```

- Read-only: installs no drivers, changes no configuration, sends no test page
- Prints `[PASS]` / `[FAIL]` per case, and exits with code 1 if anything fails

![Self-test passing 31 cases](docs/images/selftest.png)

---

## 🔏 Security notes

`Printer_Backup/` contains printer names, IP addresses, ports, share paths, the **computer name and user name** of the old PC, the exported driver packages and the logs.

**Treat it as internal material. Do not upload or share it publicly.**

This repository contains only the three scripts and the documentation; `.gitignore` excludes backup output, driver files and logs.

---

## 📄 License

No open-source license has been chosen yet. **Please do not redistribute until the author grants permission.**
