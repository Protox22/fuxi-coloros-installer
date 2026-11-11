Paczka testowa Ace5 ColorOS 17 dla Xiaomi 13 (fuxi), R783.

Wersja 2.6.1 obsługuje powiększenie super z 9 do 11 GiB ze slotu A lub B
przy czystej instalacji. TWRP i AVB są zapisywane w aktywnym slocie.

R784 (opis historyczny): na polecenie użytkownika zmieniono Windows flash.ps1/common.ps1.
Instalator Windows akceptuje aktywny slot A lub B przy istniejącym super
11 GiB. Zapisuje port wyłącznie do A oraz wspólnego super. Dopiero po
udanym zapisie wszystkich obrazów i erase userdata/metadata ustawia A,
odczytuje current-slot i żąda restartu. Błąd wcześniejszego zapisu lub
aktywacji zatrzymuje skrypt bez żądania restartu. Nie zapisuje obrazów _b.
Start B + super 9 GiB jest odrzucany przed zapisem: stara ścieżka resize
wymaga aktywnego A do startu dostarczonego recovery. Restore i Bash
zachowują wcześniejsze wymaganie A. Obrazy, APK, narzędzia i źródłowe ZIP-y
są niezmienione. Archiwum R783 nie zawiera tej poprawki Windows.
Ten opis oraz PORT_R783.json dokumentują bieżący zestaw.

Zestaw: system R369, boot/vendor_boot/recovery/kernel R429, system_ext R700,
vendor/ODM R776, vendor_dlkm R755; pozostałe obrazy zgodnie z R273.
super.img.zst zawiera osiem partycji: system, system_ext, product, vendor,
odm, vendor_dlkm, system_dlkm, mi_ext. Obrazy boot, init_boot, vendor_boot,
recovery, dtbo, vbmeta i vbmeta_system są osobno w images/ i są wybierane
przez istniejący instalator. Nie dodano bootloaderów ani cudzych danych.
Wszystkie APK, w tym SystemUI, i ich podpisy pozostały fabryczne.

Baza wskazana przez dokumentację projektu: OS3.0.306.0.WMCMIXM (Global fuxi).
Profil paczki ma tę wartość. Stary README_RU.txt pochodzi z oryginalnego
instalatora; jego starsza nazwa ROM-u i baza 304 nie opisują tego payloadu.
Wymagania: odblokowany bootloader oraz obsługiwana geometria sprawdzana
przez scripts/prepare-super.sh. Aktualizacja bez kasowania wymaga slotu A.

Instalator w oryginalnej postaci obsługuje super 11 GiB. Ze stockowych 9 GiB
przewiduje zmianę GPT/super/userdata po swoich potwierdzeniach, a następnie
usuwa userdata i metadata. Przygotowanie tej paczki NIE uruchamia flasha,
resize, wipe, recovery ani restartu telefonu. Jeżeli te operacje są
niedozwolone na Twoim urządzeniu, nie uruchamiaj FLASH.bat / flash.sh.

To snapshot obecnego stanu portu, a nie potwierdzone wydanie uniwersalne.
Czysty start po stocku NIE był testowany. Aktualnie działający telefon ma
mieszany zestaw firmware: R728 wykazał 18 różnic względem paczki stock 306.
Zgodność całego firmware i rozruch każdego egzemplarza nie są potwierdzone.

Nadal otwarte: automat/profilowanie QSPM (gotowa poprawka ODM R779 nie jest
w tym snapshotcie; nie została jeszcze zbudowana ani wdrożona), FileManager
DST, brakujące kontrakty FOD, inne sharedFd/UID-y, CNE clean-install
bootstrap i fizyczne IMS/MMS oraz pełne P0/P1/refresh/stabilność.
Konfiguracja restricted UID CNE zapisana w /data nie znajduje się w IMG.
Paczka nie zawiera /data, persist, partycji slotu B ani automatycznego rollbacku.

Weryfikacja bez poleceń urządzenia:
  Windows: powershell -ExecutionPolicy Bypass -File .\flash.ps1 -VerifyOnly
  Linux/macOS: bash ./flash.sh --verify-only
Sumy SHA-256 wykrywają uszkodzenie lub pomieszanie plików; nie stanowią
dowodu poprawnego rozruchu ani zgodności firmware.

R786: poprawiono trzy obliczenia dużych wartości bajtowych dla powłoki
recovery z arytmetyką 32-bitową. Minimalna pojemność 64 GiB, wyrównanie
sektorów i kontrola końca userdata pozostają wymagane, obliczane przez
istniejący awk. Nie zmieniono granic GPT, komend zapisu ani potwierdzeń.

R787: dodano /cache do listy zwykłego odmontowania w recovery. TWRP900
montuje /dev/block/sda29 jako /cache. Nadal wymagane jest odmontowanie
wszystkich block-backed mounts przed zapisem GPT; brak force/lazy umount.
