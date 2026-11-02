# Локальные сборки

Актуальный выпуск: **2.6.0 PKG110**.

- `FUXI-INSTALLER-2.6.0-PKG110-BARE.zip` — чистый установщик, 4 736 430 байт: без всех образов прошивки и TWRP; Windows-утилиты включены. Для прошивки нужно отдельно добавить соответствующие образы PKG110. CRC/SHA-256 каждого файла проверены; 12 сценариев упаковки прошли.
- `FUXI-INSTALLER-2.6.0-bare-build.json` — состав, исключённые файлы и SHA-256 чистого архива. Сборка: `python tools/build_release.py --kind bare`.

- `FUXI-INSTALLER-2.6.0-PKG110-FULL.zip` — полный комплект с прошивкой; рекомендуется для начала.
- `FUXI-INSTALLER-2.6.0-PKG110-INSTALLER.zip` — установщик без большого super.img.zst.
- `FUXI-INSTALLER-2.6.0-build.json` — размеры, SHA-256 и результат проверки архивов.
- `verification-2.6.0.json` — полный PKG110: VerifyOnly Windows/Bash, zstd/sparse/LP и заголовки образов.
- `SHA256SUMS.txt` — хеши выпусков.

ZIP и образы не входят в Git. Старые архивы сохранены локально. Сборка: `python tools/build_release.py --kind both` из корня проекта.
