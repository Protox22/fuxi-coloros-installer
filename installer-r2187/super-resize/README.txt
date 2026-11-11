Fuxi super resize 1.0 — Devine Machinery
English user interface in the R2179 integrated BARE package.
The original Russian instructions are preserved in README_RU.txt.

This tool changes the physical super boundary on Xiaomi 13 (fuxi)
between 9 GiB and 11 GiB. It does not flash super.img.

Supported GPT layouts only:
  super/userdata entries 32/33, super starts at sector 854080
  super/userdata entries 31/32, super starts at sector 751680
  logical sector size 4096 bytes

The script preserves the userdata end, unique partition GUIDs and all
other GPT entries. Unknown layouts are rejected before writing. The
recovery script verifies the saved GPT backup and checks the table after
writing. If the result is wrong, it attempts to restore that backup
before leaving recovery.

Data and boot behavior
Moving the boundary makes the previous userdata unreadable. After a
successful change, this tool erases userdata and metadata and leaves
the phone in fastboot. It does not reboot into Android.

After expanding to 11 GiB, flash the matching ColorOS super image with
the installer. After restoring 9 GiB, flash an official fuxi fastboot
ROM. Do not boot Android until a matching ROM is installed.

Requirements
Unpack the matching installer on Windows. The resizer needs adb.exe,
fastboot.exe, tools/TWRP-FUXI-A17.img, images/vbmeta.img and
images/vbmeta_system.img. super.img.zst is not needed for resize alone.
The bootloader must already be unlocked. Connect exactly one phone.
This R2179 package is BARE and does not include those image files.

Run from the installer folder:
  RESIZE.bat -Help
  RESIZE.bat
  RESIZE.bat check
  RESIZE.bat restore
  RESIZE.bat rescue -Backup C:\path\fuxi-gpt-YYYYMMDD-HHMMSS.bin

Type YES in uppercase to confirm. Enter or any other answer cancels.
Exit code 0 means success, 2 means cancellation before the destructive
step, and 1 means failure. Logs and GPT backups are written under
super-resize/logs and super-resize/backups. The phone serial number is
not written to those logs.

If TWRP does not open automatically, from fastboot hold Volume Up and
briefly press Power. Wait for TWRP, then run the script again. A retry
from an already open TWRP does not reflash recovery or vbmeta.

Offline test with Python 3 and Bash:
  python3 tests/test_prepare.py
The test uses a mock sgdisk and does not access a phone.
