#!/usr/bin/env python3
"""Run after an intentional ROM update. Python 3.8+; no device commands."""
import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / 'scripts'))
from payload import prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', help='ASCII ROM version/name')
    parser.add_argument('--base-firmware', help='Required starting Xiaomi firmware')
    parser.add_argument('--extra-images', help='Explicit list, e.g. boot,init_boot,vendor_boot,dtbo; empty to retain them')
    parser.add_argument('--installer-only', action='store_true', help='Keep the known missing super checksum; cannot change the firmware profile')
    args = parser.parse_args()
    try:
        profile, count, incomplete = prepare(Path(__file__).resolve().parent, **vars(args))
        print(f"Prepared {profile['name']}: {count} checksums; extra images: {profile['extra_images'] or '(none)'}")
        print('Installer-only template: add the matching super before flashing.' if incomplete else
              'Complete payload prepared. Run VerifyOnly before distributing or flashing.')
        print('Hashes detect damage and mixed versions; they do not certify ROM compatibility or origin.')
        return 0
    except (OSError, ValueError, UnicodeError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
