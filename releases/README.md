# Локальные сборки

Актуальный выпуск — [**2.6.1 PKG110**](https://github.com/Protox22/fuxi-coloros-installer/releases/tag/v2.6.1).

- `FUXI-INSTALLER-2.6.1-PKG110-BARE.zip` — установщик с Windows-утилитами. Для прошивки нужны отдельные образы и TWRP, соответствующие манифесту PKG110 от 30.10.2026.
- `FUXI-INSTALLER-2.6.1-bare-build.json` — состав, исключённые файлы и SHA-256 архива.
- [Чейнджлог 2.6.1](../docs/CHANGELOG.md).

## 2.6.0

- `FUXI-INSTALLER-2.6.0-PKG110-BARE.zip` — чистый установщик, 4 736 430 байт: без всех образов прошивки и TWRP; Windows-утилиты включены. Для прошивки нужно отдельно добавить соответствующие образы PKG110. CRC/SHA-256 каждого файла проверены; 12 сценариев упаковки прошли.
- `FUXI-INSTALLER-2.6.0-bare-build.json` — состав, исключённые файлы и SHA-256 чистого архива. Сборка: `python tools/build_release.py --kind bare`.

- `FUXI-INSTALLER-2.6.0-PKG110-FULL.zip` — полный комплект с прошивкой; рекомендуется для начала.
- `FUXI-INSTALLER-2.6.0-PKG110-INSTALLER.zip` — установщик без большого super.img.zst.
- `FUXI-INSTALLER-2.6.0-build.json` — размеры, SHA-256 и результат проверки архивов.
- `verification-2.6.0.json` — полный PKG110: VerifyOnly Windows/Bash, zstd/sparse/LP и заголовки образов.
- `SHA256SUMS.txt` — хеши выпусков.

ZIP и образы не входят в Git. Старые архивы сохранены локально. Сборка: `python tools/build_release.py --kind both` из корня проекта.
