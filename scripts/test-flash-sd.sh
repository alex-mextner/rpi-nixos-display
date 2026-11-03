#!/usr/bin/env bash
# Тесты scripts/flash-sd.sh без root и без реальных дисков:
#   1) выбор/отказ устройства — --dry-run на подставленном выводе lsblk (FLASH_SD_LSBLK_FIXTURE);
#   2) логика host-ключа (копия в tmpfs, сверка отпечатка, восстановление) на временных каталогах.
# Запуск: bash scripts/test-flash-sd.sh
# shellcheck disable=SC2015,SC1090,SC1091,SC2016,SC2034,SC2154,SC2329
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/flash-sd.sh"
work=$(mktemp -d)
# Копии ключей тестов живут в СВОЁМ tmpfs-каталоге: чужие резервные копии (настоящая прошивка) не затрагиваются.
keybase=$(mktemp -d /dev/shm/flash-sd-test.XXXXXX)
trap 'find "$keybase" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$keybase" "$work"' EXIT
export FLASH_SD_KEY_BASE="$keybase" FLASH_SD_LOCK="$work/lock"
fails=0

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  fails=$((fails + 1))
}

# Образ-заглушка: только чтобы проверки образа проходили
head -c 1000000 /dev/zero >"$work/x.img"
zstd -q --rm "$work/x.img"
image="$work/x.img.zst"

# line NAME TYPE RM TRAN SIZE MODEL MOUNT LABEL PKNAME — строка в формате lsblk -P
line() {
  printf 'NAME="%s" PATH="/dev/%s" TYPE="%s" RM="%s" TRAN="%s" SIZE="%s" VENDOR="V" MODEL="%s" MOUNTPOINTS="%s" LABEL="%s" PKNAME="%s"\n' \
    "$1" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}
GB=1000000000
card() { # card NAME [RM] [ROOT_MOUNT] [LABELS_OK]
  local n=$1 rm=${2:-1} mnt=${3:-/run/media/u/NIXOS_SD} labels=${4:-1}
  line "$n" disk "$rm" usb $((32 * GB)) Card "" "" ""
  line "${n}1" part "$rm" "" $((31 * 1000000)) "" /run/media/u/FIRMWARE "$([[ $labels == 1 ]] && echo FIRMWARE)" "$n"
  line "${n}2" part "$rm" "" $((31 * GB)) "" "$mnt" "$([[ $labels == 1 ]] && echo NIXOS_SD)" "$n"
}
internal() {
  line sda disk 0 usb $((931 * GB)) Backups "" "" ""
  line sda1 part 0 "" $((931 * GB)) "" /run/media/u/backups "" sda
  line nvme0n1 disk 0 nvme $((512 * GB)) Kingston "" "" ""
  line nvme0n1p4 part 0 "" $((412 * GB)) "" / "" nvme0n1
}

# expect_dry NAME RC FRAGMENT ARGS… — fixture читается из $work/fx
expect_dry() {
  local name=$1 rc=$2 frag=$3 out got
  shift 3
  out=$(FLASH_SD_LSBLK_FIXTURE="$work/fx" bash "$script" --dry-run --image "$image" "$@" 2>&1)
  got=$?
  if [[ $got -eq $rc && $out == *"$frag"* ]]; then pass "$name (rc=$got)"; else
    fail "$name: ожидали rc=$rc и «$frag», получили rc=$got"
    printf '%s\n' "$out"
  fi
}

{ internal; card sdc; } >"$work/fx"
expect_dry "единственная карта выбирается сама" 0 "/dev/sdc"
expect_dry "--device совпадает с картой" 0 "проверки пройдены" --device /dev/sdc
expect_dry "sda (backups) отвергнут" 2 "отвергнут" --device /dev/sda
expect_dry "nvme отвергнут" 2 "смонтирован как системный путь /" --device /dev/nvme0n1

{ internal; card sdc 0; } >"$work/fx"
expect_dry "не removable отвергнут" 2 "не removable" --device /dev/sdc
expect_dry "не removable: автовыбор отказывает" 2 "найдено: 0"

{ internal; card sdc 1 /; } >"$work/fx"
expect_dry "раздел смонтирован как / отвергнут" 2 "системный путь /" --device /dev/sdc

{ internal; card sdc 1 /boot/firmware; } >"$work/fx"
expect_dry "раздел смонтирован как /boot* отвергнут" 2 "системный путь /boot/firmware" --device /dev/sdc

{ internal; card sdc 1 /run/media/u/NIXOS_SD 0; } >"$work/fx"
expect_dry "без меток FIRMWARE/NIXOS_SD отвергнут" 2 "нужен ровно один раздел с меткой" --device /dev/sdc

# карта с 3-м разделом, поверх которого crypt-устройство с корнем текущей системы
{
  internal
  card sdc
  line sdc3 part 1 "" $((GB)) "" "" "" sdc
  line cryptroot crypt 0 "" $((GB)) "" / "" sdc3
} >"$work/fx"
expect_dry "crypt-потомок с / отвергнут" 2 "системный путь /" --device /dev/sdc
expect_dry "crypt-потомок: тип устройства указан" 2 "типа crypt" --device /dev/sdc

{ internal; card sdc; card sdd; } >"$work/fx"
expect_dry "две карты: автовыбор отказывает" 2 "найдено: 2"
expect_dry "две карты, но --device указан" 0 "проверки пройдены" --device /dev/sdd

{ internal; } >"$work/fx"
expect_dry "карты нет совсем" 2 "найдено: 0"

{ internal; card sdc; } >"$work/fx"
out=$(bash "$script" --yes --image "$image" 2>&1)
[[ $? -eq 64 ]] && pass "--yes без --device запрещён" || fail "--yes без --device"
out=$(FLASH_SD_LSBLK_FIXTURE="$work/fx" bash "$script" --image "$image" 2>&1)
[[ $out == *"только с --dry-run"* ]] && pass "фикстура без --dry-run запрещена" || fail "фикстура без --dry-run"

# ── host-ключ ────────────────────────────────────────────────────────────────
source "$script"
set +e

mkkey() { ssh-keygen -q -t ed25519 -N "" -C "root@rpi4" -f "$1"; }
mkkey "$work/k1"
mkkey "$work/k2"

(stash_key "$work/k1" "$work/k1.pub" && [[ -s "$KEY_DIR/key" && $(stat -c %a "$KEY_DIR/key") == 600 ]] \
  && [[ $(findmnt -no FSTYPE -T "$KEY_DIR") == tmpfs ]] \
  && [[ $KEY_FP == "$(ssh-keygen -lf "$work/k1.pub" | awk '{print $2}')" ]] \
  && cmp -s "$work/k1" "$KEY_DIR/key"; rc=$?; find "$KEY_DIR" -type f -exec shred -u {} +; rmdir "$KEY_DIR"; exit $rc) \
  && pass "копия ключа в tmpfs: 0600, совпадает, отпечаток снят" || fail "stash_key успех"

(stash_key "$work/k1" "$work/k2.pub") >/dev/null 2>&1 \
  && fail "чужой .pub принят" || pass "приватный ключ не соответствует .pub → отказ"

: >"$work/empty"
(stash_key "$work/empty" "$work/k1.pub") >/dev/null 2>&1 \
  && fail "пустой ключ принят" || pass "пустой приватный ключ → отказ"

(stash_key "$work/нет" "$work/k1.pub") >/dev/null 2>&1 \
  && fail "отсутствующий ключ принят" || pass "ключа нет → отказ"

ssh-keygen -q -t ed25519 -N "secret" -f "$work/k3"
(stash_key "$work/k3" "$work/k3.pub") >/dev/null 2>&1 \
  && fail "ключ с парольной фразой принят" || pass "ключ с парольной фразой → отказ (Pi не сможет его прочитать)"

rm -f "$work/nopub.pub"
cp "$work/k1" "$work/nopub"
(stash_key "$work/nopub" "$work/nopub.pub") >/dev/null 2>&1 \
  && fail "без .pub принят" || pass "нет .pub → отказ"

# install_key требует владельца root — под fakeroot
root_test=$(
  cat <<'EOS'
set -u
source "$1"
set +e
work=$2
KEY_DIR=$(mktemp -d /dev/shm/flash-sd-test.XXXXXX)
chmod 700 "$KEY_DIR"
cp "$work/k1" "$KEY_DIR/key"; cp "$work/k1.pub" "$KEY_DIR/key.pub"; chmod 600 "$KEY_DIR/key"
KEY_FP=$(ssh-keygen -lf "$work/k1.pub" | awk '{print $2}')
root=$(mktemp -d)
install_key "$root" && echo INSTALL_OK
[[ $(stat -c '%a %U' "$root/etc/ssh/ssh_host_ed25519_key") == "600 root" ]] && echo PERMS_OK
[[ $(stat -c '%a' "$root/etc/ssh/ssh_host_ed25519_key.pub") == 644 ]] && echo PUB_PERMS_OK
# подмена ключа на новой карте должна ловиться
cp "$work/k2" "$root/etc/ssh/ssh_host_ed25519_key"; cp "$work/k2.pub" "$root/etc/ssh/ssh_host_ed25519_key.pub"
KEY_FP_BAD="SHA256:другой"
KEY_FP=$KEY_FP_BAD
install_key "$root" || echo MISMATCH_CAUGHT
find "$KEY_DIR" -type f -exec shred -u {} +; rmdir "$KEY_DIR"; rm -rf "$root"
# symlink etc -> за пределы карты: отказ, ничего не записано по ссылке
root2=$(mktemp -d); outside=$(mktemp -d)
ln -s "$outside" "$root2/etc"
KEY_DIR=$(mktemp -d /dev/shm/flash-sd-test.XXXXXX); cp "$work/k1" "$KEY_DIR/key"; cp "$work/k1.pub" "$KEY_DIR/key.pub"
KEY_FP=$(ssh-keygen -lf "$work/k1.pub" | awk '{print $2}')
install_key "$root2" 2>/dev/null || echo SYMLINK_REFUSED
[[ -z $(ls -A "$outside") ]] && echo NOTHING_ESCAPED
find "$KEY_DIR" -type f -exec shred -u {} +; rmdir "$KEY_DIR"; rm -rf "$root2" "$outside"
EOS
)
res=$(fakeroot bash -c "$root_test" _ "$script" "$work" 2>&1)
for want in INSTALL_OK PERMS_OK PUB_PERMS_OK MISMATCH_CAUGHT SYMLINK_REFUSED NOTHING_ESCAPED; do
  [[ $res == *"$want"* ]] && pass "install_key: $want" || {
    fail "install_key: $want"
    printf '%s\n' "$res"
  }
done

# ── сквозной прогон main() с подменой dd/mount/lsblk (под fakeroot, без реальных дисков) ──
cat >"$work/e2e.sh" <<'EOS'
set -u
script=$1 work=$2 scenario=$3 image=$4
source "$script"
set +e
export FLASH_SD_MNT_BASE="$work/mnt"
mkdir -p "$FLASH_SD_MNT_BASE" "$work/captured"
FX="$work/e2e-fx"
lsblk() { if [[ ${1:-} == -P ]]; then cat "$FX"; else echo "/dev/sdc2 part"; fi; }
dd() {
  cat >/dev/null
  : >"$work/dd-called"
  [[ $scenario != dd_fail ]]
}
zstdcat() { printf img; }
open_device() {
  if [[ $scenario == open_fail ]]; then return 1; fi
  exec 3>"$work/fake-dev"
}
# на реальной машине /dev/sdc может существовать и быть смонтирован — подмена скрывает это
findmnt() { if [[ " $* " == *" --source "* ]]; then return 1; fi; command findmnt "$@"; }
partprobe() { :; }
udevadm() { :; }
blockdev() { :; }
sleep() { :; }
blkid() { echo NIXOS_SD; }
verify_written_prefix() { [[ $scenario != verify_fail ]]; }
mount() { :; }
umount() {
  if [[ $1 == "$FLASH_SD_MNT_BASE"/* ]]; then
    cp -a "$1/etc/ssh/." "$work/captured/" 2>/dev/null
    rm -rf "${1:?}/etc"
  fi
}
if [[ $scenario == bad_key ]]; then
  install() {
    command install "$@"
    if [[ ${*: -1} == */ssh_host_ed25519_key ]]; then
      cp "$work/k2" "${*: -1}"
      cp "$work/k2.pub" "${*: -1}.pub"
    fi
  }
fi
if [[ $scenario == hotplug ]]; then
  confirm() { grep -v 'sdc' "$FX" >"$FX.new"; cat "$FX.new" "$work/replacement" >"$FX"; }
fi
( set -e; main --image "$image" --device /dev/sdc --yes --hostkey "$work/k1" )
echo "RC=$?"
EOS

run_e2e() { # run_e2e СЦЕНАРИЙ → печатает вывод; RC=… последняя строка
  rm -rf "${work:?}/captured" "${work:?}/dd-called" "${work:?}/mnt"
  { internal; card sdc; } >"$work/e2e-fx"
  card sdc | sed 's/MODEL="Card"/MODEL="Other"/' >"$work/replacement"
  fakeroot bash "$work/e2e.sh" "$script" "$work" "$1" "$image" 2>&1
}
# Каталоги ключей других запусков (в т.ч. настоящей прошивки от root) не трогаем:
# считаем и удаляем только те, что появились после снимка перед сценарием.
snap() { find "$keybase" -maxdepth 1 -name 'flash-sd-key.*' 2>/dev/null | sort; }
new_keydirs() { comm -13 <(printf '%s\n' "$1") <(snap); }
count_new() { new_keydirs "$1" | grep -c . || true; }
drop_new() {
  local d
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    find "$d" -type f -exec shred -u {} +
    rmdir "$d"
  done < <(new_keydirs "$1")
}
orig_fp=$(ssh-keygen -lf "$work/k1.pub" | awk '{print $2}')

before=$(snap)
out=$(run_e2e ok)
if [[ $out == *"Карту можно вынимать"* && $out == *"RC=0"* && $(count_new "$before") -eq 0 \
  && -s "$work/captured/ssh_host_ed25519_key" && $(ssh-keygen -lf "$work/captured/ssh_host_ed25519_key.pub" | awk '{print $2}') == "$orig_fp" \
  && $(cat "$work/captured/ssh_host_ed25519_key") == "$(cat "$work/k1")" ]]; then
  pass "e2e: успех — ключ восстановлен с тем же отпечатком, копия в tmpfs уничтожена"
else
  fail "e2e: успех"
  printf '%s\n' "$out"
fi
drop_new "$before"

before=$(snap)
out=$(run_e2e dd_fail)
if [[ $out != *"можно вынимать"* && $out == *"СОХРАНЕНА"* && $out == *"RC=1"* && $(count_new "$before") -eq 1 ]]; then
  pass "e2e: сбой dd на полпути — ключ сохранён в tmpfs, «можно вынимать» не печатается"
else
  fail "e2e: сбой dd"
  printf '%s\n' "$out"
fi
drop_new "$before"

before=$(snap)
out=$(run_e2e bad_key)
if [[ $out != *"можно вынимать"* && $out == *"НЕ совпал"* && $out == *"RC=1"* && $(count_new "$before") -eq 1 ]]; then
  pass "e2e: ключ на новой карте не совпал — ошибка, «можно вынимать» не печатается, копия сохранена"
else
  fail "e2e: несовпадение ключа"
  printf '%s\n' "$out"
fi
drop_new "$before"

before=$(snap)
out=$(run_e2e hotplug)
if [[ $out == *"RC=2"* && $out != *"Пишу образ"* && ! -e "$work/dd-called" && $(count_new "$before") -eq 0 ]]; then
  pass "e2e: карту заменили во время подтверждения — запись отменена, dd не вызывался"
else
  fail "e2e: замена карты"
  printf '%s\n' "$out"
fi
drop_new "$before"

before=$(snap)
out=$(run_e2e open_fail)
if [[ $out == *"RC=1"* && $out == *"не удалось открыть"* && $out != *"Размонтирую"* && ! -e "$work/dd-called" && $(count_new "$before") -eq 0 ]]; then
  pass "e2e: устройство не открылось — ничего не размонтировано и не записано, копия ключа уничтожена"
else
  fail "e2e: сбой открытия устройства"
  printf '%s\n' "$out"
fi
drop_new "$before"

before=$(snap)
out=$(run_e2e verify_fail)
if [[ $out == *"RC=1"* && $out == *"не совпало с образом"* && $out != *"можно вынимать"* && $(count_new "$before") -eq 1 ]]; then
  pass "e2e: начало карты после записи не совпало с образом — отказ, копия ключа сохранена, ключ на карту не кладётся"
else
  fail "e2e: сверка записанного"
  printf '%s\n' "$out"
fi
drop_new "$before"

# блокировка: пока другой запуск держит замок, второй отказывает до любых действий
rm -f "$work/dd-called"
before=$(snap)
out=$(flock -n "$work/lock" bash -c 'fakeroot bash "$1" "$2" "$3" "$4" "$5" 2>&1' _ "$work/e2e.sh" "$script" "$work" ok "$image")
if [[ $out == *"уже работает"* && ! -e "$work/dd-called" ]]; then pass "второй одновременный запуск отказывает"; else
  fail "блокировка"
  printf '%s\n' "$out"
fi
drop_new "$before"

# сверка начала записанного устройства (обычный файл вместо блочного)
head -c 70000000 /dev/zero >"$work/big.img"
zstd -q -f "$work/big.img" -o "$work/big.img.zst"
cp "$work/big.img" "$work/dev-ok"
verify_written_prefix "$work/big.img.zst" "$work/dev-ok" && pass "verify_written_prefix: совпадает" || fail "verify_written_prefix совпадение"
cp "$work/big.img" "$work/dev-bad"
printf 'X' | dd of="$work/dev-bad" bs=1 seek=50000000 conv=notrunc status=none
verify_written_prefix "$work/big.img.zst" "$work/dev-bad" && fail "verify_written_prefix пропустил расхождение" || pass "verify_written_prefix: расхождение в первых 64 МиБ ловится"

# ключ на старой карте: обычный путь принимается, ссылка за пределы карты — отказ
cardroot="$work/oldcard"; outside="$work/outside-ssh"
mkdir -p "$cardroot/etc/ssh" "$outside"
cp "$work/k1" "$cardroot/etc/ssh/ssh_host_ed25519_key"; cp "$work/k1.pub" "$cardroot/etc/ssh/ssh_host_ed25519_key.pub"
cp "$work/k2" "$outside/ssh_host_ed25519_key"; cp "$work/k2.pub" "$outside/ssh_host_ed25519_key.pub"
card_stash() { # card_stash КОРЕНЬ — stash_key_from_card на подставной карте; печатает отпечаток или ошибку
  (
    ROOT="$1"
    findmnt() { if [[ " $* " == *" --source "* ]]; then printf '%s\n' "$ROOT"; else command findmnt "$@"; fi; }
    D_KIDS[sdc]=$'sdc2\n'; D_LABEL[sdc2]=NIXOS_SD; D_PATH[sdc2]=/dev/sdc2; DEV_NAME=sdc
    stash_key_from_card && printf 'STASHED %s\n' "$KEY_FP"
    if [[ -n "${KEY_DIR:-}" ]]; then find "$KEY_DIR" -type f -exec shred -u {} +; rmdir "$KEY_DIR"; fi
  ) 2>&1
}
res=$(card_stash "$cardroot")
[[ $res == *"STASHED $orig_fp"* || $res == *"STASHED SHA256:"* ]] && pass "ключ старой карты читается" || { fail "чтение ключа старой карты"; printf '%s\n' "$res"; }
rm -rf "$cardroot/etc/ssh"; ln -s "$outside" "$cardroot/etc/ssh"
res=$(card_stash "$cardroot")
[[ $res == *"за пределы карты"* && $res != *STASHED* ]] && pass "etc/ssh -> каталог вне карты → отказ" || { fail "symlink на каталог"; printf '%s\n' "$res"; }
rm -f "$cardroot/etc/ssh"; mkdir "$cardroot/etc/ssh"
ln -s "$outside/ssh_host_ed25519_key" "$cardroot/etc/ssh/ssh_host_ed25519_key"; cp "$outside/ssh_host_ed25519_key.pub" "$cardroot/etc/ssh/ssh_host_ed25519_key.pub"
res=$(card_stash "$cardroot")
[[ $res == *"за пределы карты"* && $res != *STASHED* ]] && pass "symlink на отдельный ключ вне карты → отказ" || { fail "symlink на ключ"; printf '%s\n' "$res"; }

# контрольная сумма привязана к имени выбранного файла
mkdir -p "$work/sums"
head -c 100000 /dev/zero | zstd -q -o "$work/sums/a.img.zst"
head -c 200000 /dev/zero | zstd -q -o "$work/sums/b.img.zst"
(cd "$work/sums" && sha256sum a.img.zst >b.img.zst.sha256)
res=$( (IMAGE="$work/sums/b.img.zst"; check_image) 2>&1 )
[[ $res == *"не содержит строки"* || $res == *"не совпал"* ]] && pass "чужая строка в .sha256 не подходит выбранному образу" || { fail "sha256 привязка"; printf '%s\n' "$res"; }
(cd "$work/sums" && sha256sum b.img.zst >b.img.zst.sha256)
res=$( (IMAGE="$work/sums/b.img.zst"; check_image) 2>&1 )
[[ $res == *"sha256 образа совпал"* ]] && pass "верная строка .sha256 принимается" || { fail "sha256 верная"; printf '%s\n' "$res"; }

# два раздела NIXOS_SD: неоднозначно, какой ключ сохранять
{
  internal
  card sdc
  line sdc3 part 1 "" $((GB)) "" "" NIXOS_SD sdc
} >"$work/fx"
expect_dry "два раздела NIXOS_SD → отказ" 2 "ровно один раздел с меткой NIXOS_SD" --device /dev/sdc

# образ на самой карте: отказ до размонтирования
mkdir -p "$work/cardmnt"
cp "$image" "$work/cardmnt/x.img.zst"
{ internal; card sdc 1 "$work/cardmnt"; } >"$work/fx"
expect_dry "образ лежит на карте → отказ" 2 "лежит на карте" --device /dev/sdc --image "$work/cardmnt/x.img.zst"

# ── вместимость карты и RAID с общим родителем ─────────────────────────────────
head -c 3000000 /dev/zero | zstd -q -o "$work/stream.img.zst"
[[ $(image_raw_size "$work/stream.img.zst") -eq 3000000 ]] \
  && pass "размер образа без размера в zstd-кадре определяется распаковкой" || fail "image_raw_size для потока"

# RAID /dev/md0 (смонтирован как /var) поверх sdc3 и sdd1: lsblk повторяет md0 под каждым родителем
{
  internal
  card sdc
  line sdc3 part 1 "" $((GB)) "" "" "" sdc
  line sdd disk 1 usb $((32 * GB)) Other "" "" ""
  line sdd1 part 1 "" $((GB)) "" "" "" sdd
  line md0 raid1 0 "" $((GB)) "" /var "" sdc3
  line md0 raid1 0 "" $((GB)) "" /var "" sdd1
} >"$work/fx"
expect_dry "RAID с общим родителем, смонтированный как /var, отвергнут" 2 "системный путь /var" --device /dev/sdc

if ((fails)); then
  printf '\n%d тест(ов) провалено\n' "$fails"
  exit 1
fi
printf '\nвсе тесты прошли\n'
