#!/usr/bin/env bash
# Прошивка готового образа rpi4-kiosk.img.zst на SD-карту с сохранением SSH host-ключа Pi.
#
#   sudo bash flash-sd.sh [--image ФАЙЛ] [--device /dev/sdX] [--hostkey ФАЙЛ] [--yes] [--dry-run]
#
# Зачем ключ: приватный /etc/ssh/ssh_host_ed25519_key лежит ТОЛЬКО на карте, а sops-nix
# расшифровывает им secrets/secrets.yaml (Wi-Fi-пароль). Прошивка стирает карту, поэтому
# ключ до записи копируется в tmpfs (/dev/shm, 0600), сверяется с .pub по отпечатку,
# после записи кладётся в корневой раздел нового образа и сверяется ещё раз; копия
# уничтожается (shred) только после успешной сверки.
#
# Карта определяется сама и ОБЯЗАНА быть ровно одна: съёмный (removable) USB-диск
# 4..256 ГиБ с разделами FIRMWARE и NIXOS_SD, ни один раздел которого не смонтирован как
# / /boot* /home /nix /usr /var /etc …; nvme*, loop*, sda и всё прочее отвергается.
# Перед стиранием печатается устройство/модель/размер/разделы и требуется ввести путь
# устройства. --dry-run выполняет все проверки и печатает план, но ничего не меняет.
#
# Коды выхода: 0 — готово; 1 — ошибка; 2 — отказ по правилам безопасности; 64 — неверные аргументы.
set -euo pipefail

readonly MIN_DISK_BYTES=$((4 * 1024 * 1024 * 1024))
readonly MAX_DISK_BYTES=$((256 * 1024 * 1024 * 1024))
readonly LABEL_FIRMWARE="FIRMWARE"
readonly LABEL_ROOT="NIXOS_SD"
readonly SYSTEM_MOUNT_RE='^(/|/boot(/.*)?|/efi(/.*)?|/home(/.*)?|/nix(/.*)?|/usr(/.*)?|/var(/.*)?|/etc(/.*)?|/opt(/.*)?|/srv(/.*)?|\[SWAP\])$'

IMAGE=""
DEVICE_ARG=""
HOSTKEY_ARG=""
ASSUME_YES=0
DRY_RUN=0

# Состояние для cleanup
KEY_DIR=""
KEY_KEEP=0
MNT_DIRS=()

# lsblk: ассоциативные массивы по имени (sdc, sdc1, …)
declare -A D_TYPE D_RM D_TRAN D_SIZE D_VENDOR D_MODEL D_PATH D_MNT D_KIDS D_LABEL D_SERIAL D_PTUUID D_UUID
DISK_NAMES=()
REASONS=()
KEY_FP=""
IDENTITY_BEFORE=""
DEV_NAME=""
IMAGE_RAW_BYTES=""

msg() { printf '%s\n' "$*"; }
err() { printf 'ОШИБКА: %s\n' "$*" >&2; }
die() {
  err "$1"
  exit "${2:-1}"
}
refuse() {
  err "$1"
  exit 2
}

usage() {
  cat <<'EOF'
Использование: sudo bash flash-sd.sh [параметры]
  --image ФАЙЛ     образ .img.zst (по умолчанию ~/rpi-image/rpi4-kiosk.img.zst пользователя, вызвавшего sudo)
  --device /dev/X  явно указать карту (всё равно проходит все проверки безопасности)
  --hostkey ФАЙЛ   взять host-ключ не с карты, а из этого приватного ключа (рядом должен лежать ФАЙЛ.pub)
  --yes            не спрашивать подтверждение; допустим только вместе с --device
  --dry-run        только проверки и план, без записи (root нужен лишь для чтения ключа с карты)
  -h, --help       эта справка
EOF
}

cleanup() {
  local status=$?
  local d
  for d in "${MNT_DIRS[@]}"; do
    if mountpoint -q "$d" 2>/dev/null; then umount "$d" 2>/dev/null || true; fi
    rmdir "$d" 2>/dev/null || true
  done
  if [[ -n "$KEY_DIR" && -d "$KEY_DIR" ]]; then
    if ((KEY_KEEP)); then
      err "копия host-ключа СОХРАНЕНА в $KEY_DIR (tmpfs, исчезнет при перезагрузке) — не выключайте компьютер, пока не восстановите ключ"
    else
      find "$KEY_DIR" -type f -exec shred -u -n 1 {} + 2>/dev/null || true
      rmdir "$KEY_DIR" 2>/dev/null || true
    fi
  fi
  return "$status"
}

# ── lsblk ────────────────────────────────────────────────────────────────────

# kv_get СТРОКА КЛЮЧ — значение из вывода lsblk -P (с раскодированными \xNN)
kv_get() {
  local line=$1 key=$2 val=""
  if [[ $line =~ (^|[[:space:]])${key}=\"([^\"]*)\" ]]; then
    val=${BASH_REMATCH[2]}
  fi
  printf '%b' "$val"
}

reset_lsblk() {
  D_TYPE=() D_RM=() D_TRAN=() D_SIZE=() D_VENDOR=() D_MODEL=() D_PATH=() D_MNT=() D_KIDS=() D_LABEL=()
  D_SERIAL=() D_PTUUID=() D_UUID=()
  DISK_NAMES=()
}

read_lsblk() {
  local out line name pk
  reset_lsblk
  if [[ -n "${FLASH_SD_LSBLK_FIXTURE:-}" ]]; then
    ((DRY_RUN)) || die "FLASH_SD_LSBLK_FIXTURE допустим только с --dry-run" 64
    out=$(<"$FLASH_SD_LSBLK_FIXTURE")
  else
    out=$(lsblk -P -b -o NAME,PATH,TYPE,RM,TRAN,SIZE,VENDOR,MODEL,SERIAL,PTUUID,UUID,MOUNTPOINTS,LABEL,PKNAME)
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name=$(kv_get "$line" NAME)
    D_TYPE[$name]=$(kv_get "$line" TYPE)
    D_RM[$name]=$(kv_get "$line" RM)
    D_TRAN[$name]=$(kv_get "$line" TRAN)
    D_SIZE[$name]=$(kv_get "$line" SIZE)
    D_VENDOR[$name]=$(kv_get "$line" VENDOR)
    D_MODEL[$name]=$(kv_get "$line" MODEL)
    D_SERIAL[$name]=$(kv_get "$line" SERIAL)
    D_PTUUID[$name]=$(kv_get "$line" PTUUID)
    D_UUID[$name]=$(kv_get "$line" UUID)
    D_PATH[$name]=$(kv_get "$line" PATH)
    D_MNT[$name]=$(kv_get "$line" MOUNTPOINTS)
    # У устройства поверх нескольких дисков (RAID/LVM) lsblk повторяет строку для каждого родителя
    pk=$(kv_get "$line" PKNAME)
    if [[ -n "$pk" && $'\n'${D_KIDS[$pk]:-} != *$'\n'"$name"$'\n'* ]]; then D_KIDS[$pk]+="$name"$'\n'; fi
    D_LABEL[$name]=$(kv_get "$line" LABEL)
    if [[ ${D_TYPE[$name]} == disk ]]; then DISK_NAMES+=("$name"); fi
  done <<<"$out"
  if [[ -z "${FLASH_SD_LSBLK_FIXTURE:-}" ]]; then
    for name in "${!D_TYPE[@]}"; do
      if [[ ${D_TYPE[$name]} == part && -z ${D_LABEL[$name]} ]]; then
        D_LABEL[$name]=$(label_of "${D_PATH[$name]}")
      fi
    done
  fi
}

# label_of /dev/путь — метка ФС: lsblk бывает пуст без udev-базы, поэтому blkid и /dev/disk/by-label
label_of() {
  local dev=$1 label="" link
  if ((EUID == 0)); then
    label=$(blkid -p -o value -s LABEL "$dev" 2>/dev/null || true)
  fi
  if [[ -z "$label" ]]; then
    for link in /dev/disk/by-label/*; do
      [[ -e "$link" ]] || continue
      if [[ $(readlink -f "$link") == "$dev" ]]; then
        label=$(printf '%b' "$(basename "$link")")
        break
      fi
    done
  fi
  printf '%s' "$label"
}

# part_names РОДИТЕЛЬ — прямые потомки (устройство может быть потомком нескольких родителей)
part_names() {
  local parent=$1
  printf '%s' "${D_KIDS[$parent]:-}" | sort
}

# descendants ДИСК — все потомки (разделы и устройства поверх них: crypt/lvm/md), от ближних к дальним
descendants() {
  local parent=$1 n
  for n in $(part_names "$parent"); do
    printf '%s\n' "$n"
    descendants "$n"
  done
}

# all_mounts ДИСК — все точки монтирования диска и ВСЕХ его потомков
all_mounts() {
  local disk=$1 n
  printf '%s\n' "${D_MNT[$disk]}"
  while IFS= read -r n; do
    if [[ -n "$n" ]]; then printf '%s\n' "${D_MNT[$n]}"; fi
  done < <(descendants "$disk")
}

# disk_identity ДИСК — то, что не меняется от записи образа: путь, размер, модель, серийник
disk_identity() {
  local disk=$1
  printf '%s|%s|%s|%s' "${D_PATH[$disk]}" "${D_SIZE[$disk]}" "${D_MODEL[$disk]}" "${D_SERIAL[$disk]}"
}

# disk_signature ДИСК — отпечаток идентичности устройства (не зависит от монтирования)
disk_signature() {
  local disk=$1 n
  printf '%s|%s|%s|%s|%s\n' "${D_PATH[$disk]}" "${D_SIZE[$disk]}" "${D_MODEL[$disk]}" "${D_SERIAL[$disk]}" "${D_PTUUID[$disk]}"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    printf '%s|%s|%s|%s|%s\n' "${D_PATH[$n]}" "${D_TYPE[$n]}" "${D_SIZE[$n]}" "${D_UUID[$n]}" "${D_LABEL[$n]}"
  done < <(descendants "$disk")
}

human_size() {
  local bytes=$1
  awk -v b="$bytes" 'BEGIN { printf "%.1f ГиБ", b / 1073741824 }'
}

# evaluate_disk ДИСК — заполняет REASONS причинами отказа; пусто = годится
evaluate_disk() {
  local disk=$1 mp n have_fw=0 have_root=0 size
  REASONS=()
  [[ ${D_TYPE[$disk]} == disk ]] || REASONS+=("не диск")
  if [[ ! $disk =~ ^sd[a-z]+$ || $disk == sda ]]; then
    REASONS+=("имя $disk не подходит (разрешены sdX, кроме sda; nvme/loop/mmcblk и пр. исключены)")
  fi
  [[ ${D_RM[$disk]} == 1 ]] || REASONS+=("не removable")
  [[ ${D_TRAN[$disk]} == usb ]] || REASONS+=("транспорт '${D_TRAN[$disk]}', нужен usb")
  size=${D_SIZE[$disk]:-0}
  if ((size < MIN_DISK_BYTES || size > MAX_DISK_BYTES)); then
    REASONS+=("размер $(human_size "$size") вне диапазона 4..256 ГиБ")
  fi
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    if [[ $mp =~ $SYSTEM_MOUNT_RE ]]; then
      REASONS+=("смонтирован как системный путь $mp")
    fi
  done < <(all_mounts "$disk")
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if [[ ${D_TYPE[$n]} != part ]]; then
      REASONS+=("поверх карты есть устройство ${D_PATH[$n]} типа ${D_TYPE[$n]} (crypt/lvm/md): карта не похожа на свежепрошитый образ")
    fi
    if [[ $'\n'${D_KIDS[$disk]:-} == *$'\n'"$n"$'\n'* ]]; then
      if [[ ${D_LABEL[$n]} == "$LABEL_FIRMWARE" ]]; then have_fw=$((have_fw + 1)); fi
      if [[ ${D_LABEL[$n]} == "$LABEL_ROOT" ]]; then have_root=$((have_root + 1)); fi
    fi
  done < <(descendants "$disk")
  ((have_fw == 1)) || REASONS+=("нужен ровно один раздел с меткой $LABEL_FIRMWARE, найдено: $have_fw")
  ((have_root == 1)) || REASONS+=("нужен ровно один раздел с меткой $LABEL_ROOT, найдено: $have_root")
}

describe_disk() {
  local disk=$1 n mp
  printf '  %s  %s  %s %s\n' "${D_PATH[$disk]}" "$(human_size "${D_SIZE[$disk]}")" \
    "$(kv_trim "${D_VENDOR[$disk]}")" "$(kv_trim "${D_MODEL[$disk]}")"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    mp=${D_MNT[$n]//$'\n'/, }
    printf '    └ %s  %s  метка=%s  смонтирован: %s\n' "${D_PATH[$n]}" "$(human_size "${D_SIZE[$n]}")" \
      "${D_LABEL[$n]:--}" "${mp:--}"
  done < <(descendants "$disk")
}

kv_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

select_device() {
  local disk candidates=()
  for disk in "${DISK_NAMES[@]}"; do
    evaluate_disk "$disk"
    if ((${#REASONS[@]} == 0)); then
      candidates+=("$disk")
    elif [[ -n "$DEVICE_ARG" && ${D_PATH[$disk]} == "$DEVICE_ARG" ]]; then
      err "${D_PATH[$disk]} отвергнут:"
      printf '  - %s\n' "${REASONS[@]}" >&2
      exit 2
    fi
  done
  if [[ -n "$DEVICE_ARG" ]]; then
    for disk in "${candidates[@]}"; do
      if [[ ${D_PATH[$disk]} == "$DEVICE_ARG" ]]; then
        DEV_NAME=$disk
        return
      fi
    done
    refuse "устройство $DEVICE_ARG не найдено среди дисков"
  fi
  if ((${#candidates[@]} != 1)); then
    err "ожидается ровно одна подходящая карта, найдено: ${#candidates[@]}"
    for disk in "${candidates[@]}"; do describe_disk "$disk" >&2; done
    msg "Остальные диски отвергнуты правилами безопасности:" >&2
    for disk in "${DISK_NAMES[@]}"; do
      evaluate_disk "$disk"
      if ((${#REASONS[@]} > 0)); then
        printf '  %s: %s\n' "${D_PATH[$disk]}" "$(
          IFS=';'
          printf '%s' "${REASONS[*]}"
        )" >&2
      fi
    done
    exit 2
  fi
  DEV_NAME=${candidates[0]}
}

# ── образ ────────────────────────────────────────────────────────────────────

default_image() {
  local home
  if [[ -n "${SUDO_USER:-}" ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  else
    home=$HOME
  fi
  printf '%s/rpi-image/rpi4-kiosk.img.zst' "$home"
}

# image_raw_size ФАЙЛ — размер распакованного образа в байтах; если zstd-кадр его не хранит
# (поток сжат из stdin), считаем реальной распаковкой: без размера проверку вместимости карты не сделать.
image_raw_size() {
  local size
  size=$(zstd -lv "$1" 2>/dev/null | sed -n 's/.*Decompressed Size:.*(\([0-9]*\) B).*/\1/p' || true)
  if [[ -z "$size" ]]; then
    size=$(zstdcat -- "$1" | wc -c)
  fi
  printf '%s' "$size"
}

check_image() {
  [[ -f "$IMAGE" ]] || die "образ не найден: $IMAGE (скачайте артефакт, см. README)"
  msg "Образ: $IMAGE ($(human_size "$(stat -c %s "$IMAGE")") сжатый)"
  if [[ -f "$IMAGE.sha256" ]]; then
    # Сверяем именно выбранный файл по строке с его именем, а не «то, что написано в .sha256»
    local want got
    want=$(awk -v n="$(basename "$IMAGE")" '{ f = $2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' "$IMAGE.sha256")
    [[ -n "$want" ]] || die "$IMAGE.sha256 не содержит строки для $(basename "$IMAGE")"
    got=$(sha256sum -- "$IMAGE" | awk '{ print $1 }')
    [[ "$got" == "$want" ]] || die "sha256 образа не совпал с $IMAGE.sha256 — скачайте заново"
    msg "sha256 образа совпал"
  else
    msg "Файла $IMAGE.sha256 нет — проверяю только целостность zstd"
  fi
  zstd --test --quiet "$IMAGE" || die "образ повреждён (zstd --test)"
  IMAGE_RAW_BYTES=$(image_raw_size "$IMAGE")
}

# ── host-ключ ────────────────────────────────────────────────────────────────

pub_fields() { awk '{ print $1, $2 }' "$1"; }

fingerprint() { ssh-keygen -lf "$1" | awk '{ print $2 }'; }

# derived_pub ПРИВАТНЫЙ — «тип ключ» из приватного ключа
# Пустая парольная фраза: Pi читает ключ без участия человека, ключ с паролем ей бесполезен
derived_pub() { ssh-keygen -y -P '' -f "$1" | awk '{ print $1, $2 }'; }

# verify_key ПРИВАТНЫЙ ПУБЛИЧНЫЙ — копия непуста, это ed25519, публичная часть совпадает
verify_key() {
  local priv=$1 pub=$2 derived
  [[ -s "$priv" ]] || die "приватный ключ пуст или отсутствует: $priv"
  [[ -s "$pub" ]] || die "публичный ключ пуст или отсутствует: $pub"
  derived=$(derived_pub "$priv") || die "ssh-keygen не смог прочитать приватный ключ $priv"
  [[ $derived == ssh-ed25519\ * ]] || die "ключ $priv не ed25519"
  [[ $derived == "$(pub_fields "$pub")" ]] || die "приватный ключ $priv не соответствует публичному $pub"
}

# stash_key ПРИВАТНЫЙ ПУБЛИЧНЫЙ — копирует в tmpfs и проверяет копию
stash_key() {
  local src_priv=$1 src_pub=$2
  [[ -s "$src_priv" ]] || die "на карте нет /etc/ssh/ssh_host_ed25519_key (или он пуст): $src_priv.
Запасной путь — новый host-ключ: README, раздел «Если host-ключ потерян»; затем --hostkey ФАЙЛ."
  [[ -s "$src_pub" ]] || die "нет публичного ключа $src_pub — отпечаток сверить нечем"
  verify_key "$src_priv" "$src_pub"
  KEY_DIR=$(mktemp -d "${FLASH_SD_KEY_BASE:-/dev/shm}/flash-sd-key.XXXXXX")
  [[ $(findmnt -no FSTYPE -T "$KEY_DIR") == tmpfs ]] || die "$KEY_DIR не на tmpfs — отказ копировать приватный ключ"
  chmod 700 "$KEY_DIR"
  (umask 077 && cat "$src_priv" >"$KEY_DIR/key" && cat "$src_pub" >"$KEY_DIR/key.pub")
  chmod 600 "$KEY_DIR/key"
  cmp -s "$src_priv" "$KEY_DIR/key" || die "копия приватного ключа не совпала с оригиналом"
  verify_key "$KEY_DIR/key" "$KEY_DIR/key.pub"
  KEY_FP=$(fingerprint "$KEY_DIR/key.pub")
  [[ "$KEY_FP" == "$(fingerprint "$src_pub")" ]] || die "отпечаток копии не совпал с исходным"
}

# root_mount_of РАЗДЕЛ — выставляет ROOT_MP: существующая точка монтирования или временная ro.
# Вызывается без подоболочки, чтобы временная точка попала в MNT_DIRS и была размонтирована cleanup.
ROOT_MP=""
root_mount_of() {
  local part=$1 mp tmp
  mp=$(findmnt -rn -o TARGET --source "$part" | head -n1 || true)
  if [[ -n "$mp" ]]; then
    ROOT_MP=$(printf '%b' "$mp")
    return
  fi
  tmp=$(mktemp -d "${FLASH_SD_MNT_BASE:-/run}/flash-sd-mnt.XXXXXX")
  MNT_DIRS+=("$tmp")
  # noload: не проигрывать журнал ext4 — чтение старой карты (в том числе --dry-run) ничего на ней не меняет
  mount -o ro,noload "$part" "$tmp" || die "не удалось смонтировать $part"
  ROOT_MP=$tmp
}

stash_key_from_card() {
  local n root_part=""
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if [[ ${D_LABEL[$n]} == "$LABEL_ROOT" ]]; then root_part=${D_PATH[$n]}; fi
  done < <(part_names "$DEV_NAME")
  [[ -n "$root_part" ]] || die "не найден раздел $LABEL_ROOT"
  root_mount_of "$root_part"
  # Ссылки на карте (etc/ssh -> /etc/ssh и т. п.) не должны вывести чтение за пределы карты:
  # иначе в «ключ карты» попал бы приватный ключ самого компьютера.
  local real_root real_key real_pub
  real_root=$(readlink -f -- "$ROOT_MP")
  real_key=$(readlink -f -- "$ROOT_MP/etc/ssh/ssh_host_ed25519_key")
  real_pub=$(readlink -f -- "$ROOT_MP/etc/ssh/ssh_host_ed25519_key.pub")
  [[ $real_key == "$real_root"/* && $real_pub == "$real_root"/* ]] \
    || die "ключ на карте — ссылка за пределы карты ($real_key, $real_pub): отказ"
  stash_key "$real_key" "$real_pub"
}

# install_key КОРЕНЬ — кладёт ключ из tmpfs в новый корень и сверяет отпечаток
install_key() {
  local root=$1 dst="$1/etc/ssh" new_fp
  # etc и etc/ssh в образе обязаны быть обычными каталогами: symlink увёл бы запись ключа за пределы карты
  if [[ -L "$root/etc" || -L "$dst" ]]; then
    err "$root/etc или $dst — символическая ссылка: отказ писать ключ"
    return 1
  fi
  install -d -m 0755 -o root -g root "$root/etc" "$dst"
  install -m 0600 -o root -g root "$KEY_DIR/key" "$dst/ssh_host_ed25519_key"
  install -m 0644 -o root -g root "$KEY_DIR/key.pub" "$dst/ssh_host_ed25519_key.pub"
  sync
  cmp -s "$KEY_DIR/key" "$dst/ssh_host_ed25519_key" || return 1
  verify_key "$dst/ssh_host_ed25519_key" "$dst/ssh_host_ed25519_key.pub" || return 1
  new_fp=$(fingerprint "$dst/ssh_host_ed25519_key.pub")
  [[ "$new_fp" == "$KEY_FP" ]] || return 1
  [[ $(stat -c '%a %U' "$dst/ssh_host_ed25519_key") == "600 root" ]] || return 1
}

# ── запись ───────────────────────────────────────────────────────────────────

unmount_all() {
  local disk=$1 n p tries names
  mapfile -t names < <(descendants "$disk")
  for n in "$disk" "${names[@]}"; do
    p=${D_PATH[$n]}
    tries=0
    while findmnt -rn --source "$p" >/dev/null 2>&1; do
      umount "$p" || die "не удалось размонтировать $p"
      tries=$((tries + 1))
      ((tries < 8)) || die "$p остаётся смонтированным"
    done
  done
}

wait_root_partition() {
  local dev=$1 i p label
  for i in $(seq 1 20); do
    for p in $(lsblk -nrpo PATH,TYPE "$dev" | awk '$2 == "part" { print $1 }'); do
      label=$(blkid -p -o value -s LABEL "$p" 2>/dev/null || true)
      if [[ $label == "$LABEL_ROOT" ]]; then
        printf '%s' "$p"
        return 0
      fi
    done
    sleep 1
    udevadm settle || true
    if ((i % 5 == 0)); then partprobe "$dev" || true; fi
  done
  return 1
}

# assert_same_disk — после записи за /dev/sdX всё ещё то же физическое устройство (размер/модель/серийник)
assert_same_disk() {
  read_lsblk
  if [[ -z "${D_TYPE[$DEV_NAME]:-}" || "$(disk_identity "$DEV_NAME")" != "$IDENTITY_BEFORE" ]]; then
    die "${D_PATH[$DEV_NAME]:-устройство} после записи оказалось другим устройством — ключ не восстановлен, копия сохранена; карту не вынимать"
  fi
}

# verify_written_prefix ОБРАЗ.zst УСТРОЙСТВО — первые 64 МиБ устройства (MBR, FIRMWARE) совпадают с образом
verify_written_prefix() {
  local n=$((64 * 1024 * 1024))
  cmp -s -n "$n" <(zstdcat -- "$1") "$2"
}

# open_device /dev/X — открывает блочное устройство на запись как дескриптор 3
open_device() { exec 3>"$1"; }

confirm() {
  local dev=$1 answer
  if ((ASSUME_YES)); then return; fi
  [[ -r /dev/tty ]] || die "нет терминала для подтверждения; используйте --device … --yes"
  printf 'Для подтверждения введите путь устройства (%s): ' "$dev" >/dev/tty
  read -r answer </dev/tty
  [[ $answer == "$dev" ]] || refuse "подтверждение не совпало — ничего не записано"
}

main() {
  local dev root_part root_mp
  while (($#)); do
    case $1 in
      --image)
        IMAGE=${2:?--image требует файл}
        shift 2
        ;;
      --device)
        DEVICE_ARG=${2:?--device требует путь}
        shift 2
        ;;
      --hostkey)
        HOSTKEY_ARG=${2:?--hostkey требует файл}
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "неизвестный параметр: $1" 64
        ;;
    esac
  done
  if ((ASSUME_YES)) && [[ -z "$DEVICE_ARG" ]]; then die "--yes допустим только вместе с --device" 64; fi
  if [[ -n "$DEVICE_ARG" && ! $DEVICE_ARG =~ ^/dev/[a-z0-9]+$ ]]; then die "странный путь устройства: $DEVICE_ARG" 64; fi

  if [[ -n "${FLASH_SD_LSBLK_FIXTURE:-}" ]] && ((!DRY_RUN)); then die "FLASH_SD_LSBLK_FIXTURE допустим только с --dry-run" 64; fi
  if ((EUID != 0)) && ((!DRY_RUN)); then die "нужен root: sudo bash $0" 1; fi
  local tool
  for tool in lsblk findmnt ssh-keygen zstd zstdcat dd sha256sum mount umount partprobe udevadm shred blkid mktemp install cmp awk flock; do
    command -v "$tool" >/dev/null || die "не найден нужный инструмент: $tool"
  done
  trap cleanup EXIT

  # Одна прошивка за раз: второй запуск не должен писать в ту же карту и размонтировать чужой корень.
  if ((!DRY_RUN)); then
    exec 9>"${FLASH_SD_LOCK:-/run/lock/flash-sd.lock}"
    flock -n 9 || die "другой запуск flash-sd.sh уже работает"
  fi

  [[ -n "$IMAGE" ]] || IMAGE=$(default_image)
  check_image

  read_lsblk
  select_device
  dev=${D_PATH[$DEV_NAME]}
  if [[ -n "${IMAGE_RAW_BYTES:-}" ]] && ((IMAGE_RAW_BYTES > D_SIZE[$DEV_NAME])); then
    refuse "образ (${IMAGE_RAW_BYTES} байт) не помещается на $dev (${D_SIZE[$DEV_NAME]} байт)"
  fi
  # Образ не должен лежать на самой карте: после размонтирования он станет недоступен.
  local image_real mp
  image_real=$(readlink -f -- "$IMAGE")
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    if [[ $image_real == "$mp"/* ]]; then refuse "образ $IMAGE лежит на карте $dev ($mp): скопируйте его на другой диск"; fi
  done < <(all_mounts "$DEV_NAME")

  # Ключ ДО любых изменений: ошибка здесь = ничего не записано.
  if [[ -n "$HOSTKEY_ARG" ]]; then
    stash_key "$HOSTKEY_ARG" "$HOSTKEY_ARG.pub"
  elif ((EUID == 0)); then
    stash_key_from_card
  else
    msg "(dry-run без root: чтение host-ключа с карты пропущено)"
  fi

  msg ""
  msg "БУДЕТ СТЁРТО ПОЛНОСТЬЮ:"
  describe_disk "$DEV_NAME"
  msg "Образ: $IMAGE"
  if [[ -n "$KEY_FP" ]]; then msg "Host-ключ сохранён в tmpfs, отпечаток: $KEY_FP"; fi
  msg ""

  if ((DRY_RUN)); then
    msg "[dry-run] размонтировать все разделы $dev"
    msg "[dry-run] zstdcat -- '$IMAGE' | dd bs=4M iflag=fullblock conv=fsync status=progress  (в открытый на запись $dev)"
    msg "[dry-run] sync; partprobe $dev; смонтировать раздел $LABEL_ROOT, положить /etc/ssh/ssh_host_ed25519_key (0600 root) и .pub (0644)"
    msg "[dry-run] сверить отпечаток нового ключа с исходным${KEY_FP:+ ($KEY_FP)}, sync, umount, shred копии"
    msg "[dry-run] проверки пройдены, ничего не изменено"
    return 0
  fi

  local sig_before sig_after
  sig_before=$(disk_signature "$DEV_NAME")
  IDENTITY_BEFORE=$(disk_identity "$DEV_NAME")
  confirm "$dev"

  # Устройство открывается ОДИН раз и ДО повторной проверки; пишем только через этот дескриптор.
  # Если карту выдернут/подменят позже, запись пойдёт в то, что открыто сейчас, а не в новое /dev/sdX.
  open_device "$dev" || die "не удалось открыть $dev на запись"
  # Между проверкой и открытием карту могли заменить (пока висел вопрос): перечитать и сверить.
  read_lsblk
  [[ -n "${D_TYPE[$DEV_NAME]:-}" ]] || refuse "$dev исчез после подтверждения — ничего не записано"
  evaluate_disk "$DEV_NAME"
  if ((${#REASONS[@]} > 0)); then
    err "$dev перестал проходить проверки после подтверждения:"
    printf '  - %s\n' "${REASONS[@]}" >&2
    exit 2
  fi
  sig_after=$(disk_signature "$DEV_NAME")
  [[ "$sig_before" == "$sig_after" ]] || refuse "$dev теперь другое устройство (размер/модель/серийник/UUID изменились) — ничего не записано"

  msg "Размонтирую разделы $dev…"
  unmount_all "$DEV_NAME"
  msg "Пишу образ…"
  # С этого момента старая карта может быть испорчена (даже при сбое dd на полпути):
  # ключ остаётся в tmpfs, пока не восстановлен и не сверен на новой карте.
  KEY_KEEP=1
  zstdcat -- "$IMAGE" | dd bs=4M iflag=fullblock conv=fsync status=progress >&3
  exec 3>&-
  sync
  blockdev --flushbufs "$dev" || true
  # Читаем обратно начало карты (таблица разделов + весь FIRMWARE) и сверяем с образом:
  # ловит сбой записи и подмену карты после dd, до того как на неё ляжет ключ.
  verify_written_prefix "$IMAGE" "$dev" || die "начало $dev не совпало с образом — запись не удалась или карту подменили; карту не вынимать"
  partprobe "$dev"
  udevadm settle || true
  # Устройство после записи — то же физическое (размер/модель/серийник), что и до неё
  assert_same_disk

  root_part=$(wait_root_partition "$dev") || die "после записи не появился раздел $LABEL_ROOT на $dev"
  assert_same_disk
  # udisks мог смонтировать новую карту автоматически
  while findmnt -rn --source "$root_part" >/dev/null 2>&1; do umount "$root_part"; done
  root_mp=$(mktemp -d "${FLASH_SD_MNT_BASE:-/run}/flash-sd-mnt.XXXXXX")
  MNT_DIRS+=("$root_mp")
  mount "$root_part" "$root_mp" || die "не удалось смонтировать новый корневой раздел $root_part"
  if ! install_key "$root_mp"; then
    err "ключ на новой карте НЕ совпал с исходным (отпечаток $KEY_FP) — карту не вынимать и не загружать с неё"
    exit 1
  fi
  msg "Host-ключ восстановлен, отпечаток совпал: $KEY_FP"
  sync
  umount "$root_mp"
  rmdir "$root_mp"
  # MNT_DIRS не очищаем: cleanup доубирает и временный каталог старого корня (rmdir безвреден для уже удалённых)
  sync
  # Автомонтирование рабочего стола могло подцепить и другие разделы: вынимать можно только после umount всех
  assert_same_disk
  unmount_all "$DEV_NAME"
  sync
  KEY_KEEP=0 # сверка прошла: cleanup уничтожит копию
  msg "Готово. Карту можно вынимать."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
