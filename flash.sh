#!/bin/sh
# shellcheck shell=dash
#
# XR1710G (Airoha AN7581): replace the bootloader in the chainloader slot
# straight from the running system. Two bootloaders are offered:
#
#   http     -- https://github.com/YYH2913/http-uboot (web recovery, own DHCP)
#   openwrt  -- the standard OpenWrt chainloader from
#               https://github.com/akorshun/openwrt (boot menu, reset -> TFTP)
#
# The slot is read-only (no MTD_WRITEABLE in /sys/class/mtd/mtdN/flags), so the
# script lifts the protection with mtd-rw, writes the slot, verifies it by
# reading it back and reboots. Any mtd-rw built for the same kernel version
# loads, because the vermagic of these kernels has no config hash, and mtd-rw
# only touches mtd->flags.
#
# Steps:
#   * language and bootloader selection (-l, -u or interactive);
#   * board, partition and image checks;
#   * backup of the current slot to /root;
#   * unlocking (mtd-rw from the system, from the repository or via -m);
#   * mtd write + sha256 read-back check (automatic rollback on mismatch);
#   * the saved U-Boot environment is made to match the new bootloader;
#   * rmmod and reboot.
#
# Messages are in English or Russian: -l en|ru, $XR1710G_LANG, or a question
# at start-up.
#
set -eu

SCRIPT_VERSION="3.0"
REPO_RAW="https://raw.githubusercontent.com/akorshun/xr1710g-uboot-swap/main"
SLOT_NAME="chainloader"
SLOT_SIZE=1048576
RECOVERY_IP="192.168.255.1"
RECOVERY_MARK="HTTP recovery server listening"
OPENWRT_MARK="OpenWrt Linux-u-boot"
UIMAGE_MAGIC="27051956"
FIT_MAGIC="d00dfeed"

HTTP_IMAGE="xr1710g-chainloader-slot.bin"
HTTP_SHA256="deaefed37c13f25eb551d60951cec7077adfd01c6964174d0aa938288d27be30"
HTTP_RELEASE="YYH2913/http-uboot xr1710g_260805"
OPENWRT_IMAGE="openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb"
OPENWRT_SHA256="0876dbc4c16bbc6d451c2c4bcc156c745dce20547406c807c22855cf39dd98fb"
OPENWRT_RELEASE="akorshun/openwrt xr1710g-r7"
OPENWRT_TFTP_FILE="openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb"

# Bundled mtd-rw modules, by kernel version.
module_sha256() {
	case "$1" in
	6.18.41) echo "afbe8712be475cdbf75375ab1d1b28264e9b0578f1a840b0267d52a3c5783a62" ;;
	6.18.55) echo "c4a456d7440ad89d52e27bd16bebd352e569fea6b68cb200589c82fe1218669b" ;;
	*) return 1 ;;
	esac
}

# Test hooks.
ROOT="${XR1710G_ROOT:-}"
BACKUP_DIR="${XR1710G_BACKUP_DIR:-$ROOT/root}"
PROC_MTD="$ROOT/proc/mtd"
FW_ENV_CONFIG="$ROOT/etc/fw_env.config"

MODE="flash"
DO_REBOOT=1
ASSUME_YES=0
UI_LANG="${XR1710G_LANG:-}"
VARIANT=""
IMAGE=""
MODULE=""
RESTORE_FILE=""
WORKDIR=""
SLOT_MTD=""
SLOT_DEV=""
BACKUP_FILE=""
LAYOUT=""
LAYOUT_TEXT=""
LOADED_MODULE=0

# L <russian> <english>: the message in the selected language.
L() {
	if [ "$UI_LANG" = "ru" ]; then
		printf '%s' "$1"
	else
		printf '%s' "$2"
	fi
}

say() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$(L 'ВНИМАНИЕ' 'WARNING')" "$*" >&2; }
die() { printf '%s: %s\n' "$(L 'ОШИБКА' 'ERROR')" "$*" >&2; exit 1; }

cleanup() {
	if [ "$LOADED_MODULE" = 1 ]; then
		rmmod mtd_rw 2>/dev/null || rmmod mtd-rw 2>/dev/null || true
	fi
	if [ -n "$WORKDIR" ]; then
		rm -rf "$WORKDIR"
	fi
	return 0
}
trap cleanup EXIT HUP INT TERM

usage() {
	if [ "$UI_LANG" = "ru" ]; then
		cat <<USAGE
XR1710G: прошивка загрузчика из работающей системы (версия $SCRIPT_VERSION)

Использование: flash.sh [опции]

  -u <вариант> какой загрузчик прошить:
               http    -- http-uboot с веб-рекавери ($HTTP_RELEASE)
               openwrt -- стандартный загрузчик OpenWrt ($OPENWRT_RELEASE)
               без -u скрипт спросит (с -y берётся http)
  -l <язык>    язык сообщений: en или ru (без -l скрипт спросит)
  -i <файл>    свой образ слота; вариант определяется по заголовку
  -m <файл>    mtd-rw.ko, если в системе нет kmod-mtd-rw и в репозитории
               нет модуля под это ядро
  -r <файл>    откат: записать указанную копию слота обратно
  -b           ничего не писать: только проверки, копия слота и подсказки
  -n           не перезагружать после записи
  -y           не спрашивать подтверждение
  -h           эта справка
USAGE
	else
		cat <<USAGE
XR1710G: flash the bootloader from the running system (version $SCRIPT_VERSION)

Usage: flash.sh [options]

  -u <variant> which bootloader to flash:
               http    -- http-uboot with web recovery ($HTTP_RELEASE)
               openwrt -- the standard OpenWrt bootloader ($OPENWRT_RELEASE)
               without -u the script asks (http with -y)
  -l <lang>    message language: en or ru (without -l the script asks)
  -i <file>    your own slot image; the variant is taken from its header
  -m <file>    mtd-rw.ko, if the system has no kmod-mtd-rw and the
               repository has no module for this kernel
  -r <file>    rollback: write the given slot backup back
  -b           write nothing: checks, slot backup and hints only
  -n           do not reboot after writing
  -y           do not ask for confirmation
  -h           this help
USAGE
	fi
}

have_tty() {
	(: < /dev/tty) 2>/dev/null
}

# ask <prompt>: one line from the terminal (empty without a terminal).
ask() {
	printf '%s' "$1" > /dev/tty
	answer=""
	read -r answer < /dev/tty || answer=""
	printf '%s' "$answer"
}

confirm() {
	if [ "$ASSUME_YES" = 1 ]; then
		return 0
	fi
	if ! have_tty; then
		die "$(L 'нет доступа к терминалу для подтверждения, перезапустите с -y' \
			'no terminal to confirm on, run again with -y')"
	fi
	answer=$(ask "$1 [y/N]: ")
	case "$answer" in
	y | Y | yes | YES | Yes | да | Да | ДА) return 0 ;;
	esac
	die "$(L 'отменено пользователем' 'cancelled by the user')"
}

select_language() {
	case "$UI_LANG" in
	ru | en) return 0 ;;
	"") ;;
	*) UI_LANG="" ;;
	esac
	case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
	ru* | RU*) guess="ru" ;;
	*) guess="en" ;;
	esac
	if [ "$ASSUME_YES" = 1 ] || ! have_tty; then
		UI_LANG="$guess"
		return 0
	fi
	if [ "$guess" = "ru" ]; then
		default=2
	else
		default=1
	fi
	printf 'Language / Язык:\n  1) English\n  2) Русский\n' > /dev/tty
	choice=$(ask "[$default]: ")
	case "${choice:-$default}" in
	2 | ru | RU) UI_LANG="ru" ;;
	*) UI_LANG="en" ;;
	esac
}

select_variant() {
	case "$VARIANT" in
	http | openwrt) return 0 ;;
	"") ;;
	*) die "$(L "неизвестный вариант '$VARIANT', допустимо: http, openwrt" \
		"unknown variant '$VARIANT', expected http or openwrt")" ;;
	esac
	# With -i the variant comes from the image header, see check_image.
	if [ -n "$IMAGE" ] || [ "$MODE" != "flash" ]; then
		return 0
	fi
	if [ "$ASSUME_YES" = 1 ] || ! have_tty; then
		VARIANT="http"
		return 0
	fi
	if [ "$UI_LANG" = "ru" ]; then
		cat > /dev/tty <<MENU

Какой загрузчик прошить?
  1) http-uboot ($HTTP_RELEASE)
     веб-рекавери на http://$RECOVERY_IP со своим DHCP, порт 10GbE,
     раскладки UBI 2.0 / 1.5 / 1.0, сам уходит в рекавери при сбое загрузки
  2) OpenWrt ($OPENWRT_RELEASE)
     стандартный U-Boot OpenWrt: меню загрузки на UART, reset при
     включении -> recovery по TFTP, том recovery как запасной; только UBI 2.0
MENU
	else
		cat > /dev/tty <<MENU

Which bootloader to flash?
  1) http-uboot ($HTTP_RELEASE)
     web recovery at http://$RECOVERY_IP with its own DHCP, 10GbE port,
     UBI layouts 2.0 / 1.5 / 1.0, enters recovery by itself if boot fails
  2) OpenWrt ($OPENWRT_RELEASE)
     the standard OpenWrt U-Boot: boot menu on UART, reset at power-on ->
     recovery via TFTP, recovery volume as fallback; UBI 2.0 only
MENU
	fi
	choice=$(ask "[1]: ")
	case "${choice:-1}" in
	2 | openwrt) VARIANT="openwrt" ;;
	*) VARIANT="http" ;;
	esac
}

check_tools() {
	missing=""
	for tool in dd strings sed awk grep sha256sum head mtd insmod fw_printenv; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing="$missing $tool"
		fi
	done
	if [ -n "$missing" ]; then
		die "$(L 'в системе нет инструментов:' 'missing tools:')$missing"
	fi
	if ! command -v hexdump >/dev/null 2>&1 && ! command -v od >/dev/null 2>&1; then
		die "$(L 'нужен hexdump или od, чтобы проверить заголовок образа' \
			'hexdump or od is needed to check the image header')"
	fi
}

# hex_at <file> <offset> <count>: bytes in hex (hexdump on the router, od elsewhere).
hex_at() {
	if command -v hexdump >/dev/null 2>&1; then
		dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | hexdump -v -e '1/1 "%02x"'
	else
		dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tx1 | tr -d ' \n'
	fi
}

# image_kind <file>: http (legacy uImage), openwrt (FIT) or unknown.
image_kind() {
	case "$(hex_at "$1" 0 4)" in
	"$UIMAGE_MAGIC") echo "http" ;;
	"$FIT_MAGIC") echo "openwrt" ;;
	*) echo "unknown" ;;
	esac
}

check_board() {
	model=""
	if [ -r "$ROOT/tmp/sysinfo/board_name" ]; then
		model=$(cat "$ROOT/tmp/sysinfo/board_name")
	elif [ -r "$ROOT/proc/device-tree/compatible" ]; then
		model=$(tr -d '\000' < "$ROOT/proc/device-tree/compatible")
	fi
	if [ -z "$model" ]; then
		die "$(L 'не удалось определить модель устройства' 'cannot determine the device model')"
	fi
	case "$model" in
	*xr1710g*) say "$(L 'Устройство:           ' 'Device:               ') $model" ;;
	*) die "$(L "это не XR1710G, а '$model' -- скрипт рассчитан только на XR1710G" \
		"this is not an XR1710G but '$model' -- the script is for the XR1710G only")" ;;
	esac
}

find_mtd() {
	if [ ! -r "$PROC_MTD" ]; then
		die "$(L 'нет' 'missing') $PROC_MTD"
	fi
	awk -v want="\"$1\"" '$4 == want { sub(":", "", $1); print $1; exit }' "$PROC_MTD"
}

mtd_size() {
	awk -v want="$1:" '$1 == want { print $2; exit }' "$PROC_MTD"
}

# UBI layout from the end address of the ubi partition (as in the recovery
# selector): LAYOUT is 2.0, 1.5, 1.0, none or other, LAYOUT_TEXT describes it.
detect_layout() {
	start=0
	end=0
	while read -r dev size _ name; do
		dev=${dev%:}
		case "$dev" in mtd*) ;; *) continue ;; esac
		if [ -z "$size" ]; then
			continue
		fi
		size=$((0x$size))
		if [ "$name" = '"ubi"' ]; then
			end=$((start + size))
			break
		fi
		start=$((start + size))
	done < "$PROC_MTD"
	hex_end=$(printf '0x%x' "$end")
	case "$hex_end" in
	0x0) LAYOUT="none" ;;
	0x1be00000) LAYOUT="2.0" ;;
	0x1e0c0000) LAYOUT="1.5" ;;
	0x1fe00000) LAYOUT="1.0" ;;
	*) LAYOUT="other" ;;
	esac
	case "$LAYOUT" in
	none) LAYOUT_TEXT=$(L 'не найдена' 'not found') ;;
	other) LAYOUT_TEXT="$(L 'нестандартная (конец' 'non-standard (ends at') $hex_end)" ;;
	*) LAYOUT_TEXT="UBI $LAYOUT ($(L 'конец' 'ends at') $hex_end)" ;;
	esac
}

find_slot() {
	SLOT_MTD=$(find_mtd "$SLOT_NAME")
	if [ -z "$SLOT_MTD" ]; then
		die "$(L "в /proc/mtd нет раздела \"$SLOT_NAME\": такая раскладка не поддерживается,
       прошивайте загрузчик через UART/TFTP (см. README)" \
			"/proc/mtd has no \"$SLOT_NAME\" partition: this layout is not supported,
       flash the bootloader over UART/TFTP (see README)")"
	fi
	size=$(mtd_size "$SLOT_MTD")
	if [ "$((0x$size))" != "$SLOT_SIZE" ]; then
		die "$(L "раздел $SLOT_NAME имеет размер 0x$size, ожидался 0x100000" \
			"partition $SLOT_NAME is 0x$size bytes, expected 0x100000")"
	fi
	SLOT_DEV="$ROOT/dev/$SLOT_MTD"
	if [ ! -r "$SLOT_DEV" ]; then
		die "$(L 'нет доступа к' 'cannot read') $SLOT_DEV"
	fi
	say "$(L 'Слот загрузчика:      ' 'Bootloader slot:      ') $SLOT_MTD ($SLOT_DEV), $(L '1 МиБ' '1 MiB')"
}

sha_of() {
	sha256sum "$1" | awk '{ print $1 }'
}

# U-Boot version from an image or a slot dump.
uboot_version() {
	strings -n 8 "$1" | grep -E "^U-Boot 20[0-9][0-9]\." | head -n 1
}

# Human-readable name of the bootloader in a file.
describe_loader() {
	ver=$(uboot_version "$1")
	if [ -n "$ver" ]; then
		printf '%s\n' "$ver"
	elif [ "$(image_kind "$1")" = "openwrt" ] && strings -n 8 "$1" | grep -qF "$OPENWRT_MARK"; then
		L 'U-Boot OpenWrt (FIT)' 'OpenWrt U-Boot (FIT)'
		echo
	else
		L 'не определён' 'unknown'
		echo
	fi
}

show_current() {
	dump="$WORKDIR/slot.bin"
	dd if="$SLOT_DEV" of="$dump" bs=65536 count=16 2>/dev/null ||
		die "$(L 'не удалось прочитать' 'cannot read') $SLOT_DEV"
	say "$(L 'Текущий загрузчик:    ' 'Current bootloader:   ') $(describe_loader "$dump")"
	CURRENT_DUMP="$dump"
}

backup_slot() {
	mkdir -p "$BACKUP_DIR"
	stamp=$(date "+%Y%m%d-%H%M%S")
	BACKUP_FILE="$BACKUP_DIR/xr1710g-chainloader-$stamp.bin"
	cp "$CURRENT_DUMP" "$BACKUP_FILE"
	say "$(L 'Резервная копия:      ' 'Backup:               ') $BACKUP_FILE"
	say "  sha256:              $(sha_of "$BACKUP_FILE")"
	say "$(L '  забрать на ПК:      ' '  copy to the PC:     ') scp root@<$(L 'адрес роутера' 'router address')>:$BACKUP_FILE ."
}

# Look for a file next to the script, in /tmp, or download it from the repository.
resolve_file() {
	name="$1"
	sub="$2"
	script_dir=$(dirname "$0")
	for candidate in "$script_dir/$sub/$name" "$script_dir/$name" "$ROOT/tmp/$name"; do
		if [ -r "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	target="$WORKDIR/$name"
	if ! wget -q -O "$target" "$REPO_RAW/$sub/$name" 2>/dev/null; then
		rm -f "$target"
		return 1
	fi
	printf '%s\n' "$target"
}

check_image() {
	if [ -z "$IMAGE" ]; then
		if [ "$VARIANT" = "openwrt" ]; then
			name="$OPENWRT_IMAGE"
		else
			name="$HTTP_IMAGE"
		fi
		IMAGE=$(resolve_file "$name" firmware) || die "$(L "не нашёл $name рядом со скриптом и не смог скачать
       (у роутера нет интернета?). Положите файл в /tmp или укажите через -i" \
			"$name is not next to the script and cannot be downloaded
       (no internet on the router?). Put the file into /tmp or pass it with -i")"
	fi
	if [ ! -r "$IMAGE" ]; then
		die "$(L "файл $IMAGE не читается" "cannot read $IMAGE")"
	fi
	size=$(wc -c < "$IMAGE" | tr -d ' ')
	sum=$(sha_of "$IMAGE")
	say "$(L 'Новый образ:          ' 'New image:            ') $IMAGE"
	say "$(L '  размер:             ' '  size:               ') $size $(L 'байт' 'bytes')"
	say "  sha256:              $sum"
	if [ "$size" -gt "$SLOT_SIZE" ]; then
		die "$(L 'образ больше слота (1 МиБ)' 'the image is larger than the slot (1 MiB)')"
	fi
	kind=$(image_kind "$IMAGE")
	if [ "$kind" = "unknown" ]; then
		die "$(L "это не образ слота: нет заголовка uImage или FIT (magic $(hex_at "$IMAGE" 0 4)).
       Нужен $HTTP_IMAGE или $OPENWRT_IMAGE, а не u-boot.bin" \
			"this is not a slot image: no uImage or FIT header (magic $(hex_at "$IMAGE" 0 4)).
       Use $HTTP_IMAGE or $OPENWRT_IMAGE, not u-boot.bin")"
	fi
	if [ -n "$VARIANT" ] && [ "$VARIANT" != "$kind" ]; then
		die "$(L "образ -- загрузчик варианта '$kind', а выбран '$VARIANT'" \
			"the image is a '$kind' bootloader, but '$VARIANT' was selected")"
	fi
	VARIANT="$kind"
	if [ "$kind" = "openwrt" ] && ! strings -n 8 "$IMAGE" | grep -qF "$OPENWRT_MARK"; then
		die "$(L "это FIT, но не загрузчик OpenWrt (нет \"$OPENWRT_MARK\"): sysupgrade и
       initramfs-образы в слот загрузчика не пишутся" \
			"this is a FIT but not the OpenWrt bootloader (no \"$OPENWRT_MARK\"): sysupgrade
       and initramfs images do not go into the bootloader slot")"
	fi
	if [ "$MODE" = "flash" ]; then
		if [ "$kind" = "openwrt" ]; then
			want="$OPENWRT_SHA256"
			release="$OPENWRT_RELEASE"
		else
			want="$HTTP_SHA256"
			release="$HTTP_RELEASE"
		fi
		if [ "$sum" = "$want" ]; then
			say "$(L '  проверка:           ' '  check:              ') $(L 'совпадает с релизом' 'matches release') $release"
		else
			warn "$(L "образ не совпадает с известным релизом $release -- убедитесь в его происхождении" \
				"the image does not match the known release $release -- make sure where it comes from")"
		fi
	fi
	say "$(L '  загрузчик:          ' '  bootloader:         ') $(describe_loader "$IMAGE")"
	if [ "$kind" = "http" ] && ! strings -n 8 "$IMAGE" | grep -q "$RECOVERY_MARK"; then
		warn "$(L 'в образе нет HTTP-рекавери: в него нельзя будет войти кнопкой reset' \
			'the image has no HTTP recovery: the reset button will not enter it')"
		confirm "$(L 'Всё равно прошить такой загрузчик?' 'Flash this bootloader anyway?')"
	fi
}

# UBI volume device by name, e.g. /dev/ubi0_3 for "fit".
ubi_volume() {
	for name_file in "$ROOT"/sys/class/ubi/ubi*_*/name; do
		if [ -r "$name_file" ] && [ "$(cat "$name_file")" = "$1" ]; then
			vol=$(basename "$(dirname "$name_file")")
			printf '%s\n' "$ROOT/dev/$vol"
			return 0
		fi
	done
	return 1
}

# The OpenWrt bootloader only knows layout 2.0 and boots "ubi read fit" +
# "bootm #config-1"; check that the installed system fits that.
check_openwrt_target() {
	if [ "$LAYOUT" != "2.0" ]; then
		die "$(L "загрузчик OpenWrt работает только с раскладкой UBI 2.0, а здесь другая.
       Используйте -u http или сначала переставьте систему в раскладку 2.0" \
			"the OpenWrt bootloader supports the UBI 2.0 layout only, this one differs.
       Use -u http or move the system to layout 2.0 first")"
	fi
	fit=$(ubi_volume fit) || fit=""
	if [ -z "$fit" ] || [ ! -r "$fit" ]; then
		warn "$(L 'в UBI нет тома fit: загрузчик OpenWrt не найдёт систему и загрузится
         только в recovery (том recovery или TFTP по кнопке reset)' \
			'UBI has no fit volume: the OpenWrt bootloader will not find the system and
         will only boot recovery (the recovery volume, or TFTP with reset)')"
		confirm "$(L 'Всё равно продолжить?' 'Continue anyway?')"
		return 0
	fi
	# The configuration node name sits in the FIT structure; read the whole FDT.
	total=$((0x$(hex_at "$fit" 4 4)))
	if [ "$total" -le 0 ] || [ "$total" -gt $((64 * 1024 * 1024)) ]; then
		total=$((64 * 1024 * 1024))
	fi
	head -c "$total" "$fit" > "$WORKDIR/fit-header.bin"
	if [ "$(hex_at "$fit" 0 4)" = "$FIT_MAGIC" ] &&
		strings -n 8 "$WORKDIR/fit-header.bin" | grep -qx "config-1"; then
		say "$(L 'Система в томе fit:   ' 'System in volume fit: ') $(L 'FIT с config-1, загрузчик OpenWrt её загрузит' 'FIT with config-1, the OpenWrt bootloader will boot it')"
		return 0
	fi
	warn "$(L "в томе fit нет FIT с конфигурацией config-1: загрузчик OpenWrt запускает
         bootm \$loadaddr#config-1 и с этой системой уйдёт в recovery" \
		"the fit volume holds no FIT with configuration config-1: the OpenWrt
         bootloader runs bootm \$loadaddr#config-1 and will fall back to recovery")"
	confirm "$(L 'Всё равно продолжить?' 'Continue anyway?')"
}

slot_is_writable() {
	flags_file="$ROOT/sys/class/mtd/$SLOT_MTD/flags"
	if [ ! -r "$flags_file" ]; then
		return 1
	fi
	flags=$(cat "$flags_file")
	case "$flags" in
	0x*) ;;
	*) flags="0x$flags" ;;
	esac
	if [ "$(( flags & 0x400 ))" -ne 0 ]; then
		return 0
	fi
	return 1
}

kernel_vermagic() {
	ko=$(find "$ROOT/lib/modules" -name "*.ko" 2>/dev/null | head -n 1)
	if [ -z "$ko" ]; then
		return 1
	fi
	strings -n 8 "$ko" | sed -n 's/^vermagic=//p' | head -n 1
}

module_vermagic() {
	strings -n 8 "$1" | sed -n 's/^vermagic=//p' | head -n 1
}

unlock_slot() {
	if slot_is_writable; then
		say "$(L 'Защита раздела:       ' 'Partition protection: ') $(L 'уже снята' 'already off')"
		return 0
	fi
	say "$(L 'Защита раздела:       ' 'Partition protection: ') $(L 'включена, снимаю модулем mtd-rw' 'on, lifting it with mtd-rw')"
	if insmod mtd-rw i_want_a_brick=1 2>/dev/null; then
		LOADED_MODULE=1
	else
		kver=$(kernel_vermagic) || die "$(L 'не удалось прочитать vermagic ядра' 'cannot read the kernel vermagic')"
		krel=${kver%% *}
		known_sum=$(module_sha256 "$krel") || known_sum=""
		if [ -z "$MODULE" ]; then
			if [ -z "$known_sum" ]; then
				die "$(L "в системе нет kmod-mtd-rw, а в репозитории нет модуля под ядро $krel.
       Установите kmod-mtd-rw из kmods-репозитория своей сборки или укажите
       модуль через -m" \
					"the system has no kmod-mtd-rw and the repository has no module for
       kernel $krel. Install kmod-mtd-rw from your build's kmods feed or pass
       a module with -m")"
			fi
			name="mtd-rw-$krel.ko"
			MODULE=$(resolve_file "$name" firmware) ||
				die "$(L "в системе нет kmod-mtd-rw, и я не нашёл $name
       рядом со скриптом и не смог скачать. Возьмите его из репозитория
       (firmware/$name) и укажите через -m" \
					"the system has no kmod-mtd-rw, and $name is not next to
       the script and cannot be downloaded. Take it from the repository
       (firmware/$name) and pass it with -m")"
		fi
		if [ ! -r "$MODULE" ]; then
			die "$(L "файл модуля $MODULE не читается" "cannot read the module $MODULE")"
		fi
		msum=$(sha_of "$MODULE")
		say "$(L '  модуль:             ' '  module:             ') $MODULE"
		say "  sha256:              $msum"
		if [ "$msum" != "$known_sum" ]; then
			warn "$(L 'модуль не совпадает с проверенным из репозитория' \
				'the module does not match the tested one from the repository')"
		fi
		mver=$(module_vermagic "$MODULE")
		say "$(L '  vermagic ядра:      ' '  kernel vermagic:    ') $kver"
		say "$(L '  vermagic модуля:    ' '  module vermagic:    ') $mver"
		if [ "$kver" != "$mver" ]; then
			die "$(L 'vermagic не совпадает: этот модуль собран для другого ядра.
       Возьмите kmod-mtd-rw из kmods-репозитория своей сборки' \
				'vermagic mismatch: this module was built for another kernel.
       Take kmod-mtd-rw from your build'"'"'s kmods feed')"
		fi
		if ! insmod "$MODULE" i_want_a_brick=1; then
			die "$(L 'insmod не отработал: модуль не загрузился' 'insmod failed: the module did not load')"
		fi
		LOADED_MODULE=1
	fi
	if ! slot_is_writable; then
		die "$(L 'модуль загрузился, но раздел так и не стал доступен для записи' \
			'the module loaded, but the partition is still read-only')"
	fi
	say "$(L '  результат:          ' '  result:             ') $(L 'раздел открыт для записи' 'partition is writable')"
}

# Read-back check: compare exactly as many bytes as the image has.
verify_written() {
	file="$1"
	size=$(wc -c < "$file" | tr -d ' ')
	blocks=$(( (size + 4095) / 4096 ))
	got=$(dd if="$SLOT_DEV" bs=4096 count="$blocks" 2>/dev/null | head -c "$size" | sha256sum | awk '{ print $1 }')
	want=$(sha_of "$file")
	if [ "$got" != "$want" ]; then
		return 1
	fi
	return 0
}

write_slot() {
	file="$1"
	say ""
	say "$(L "Записываю $file в раздел $SLOT_NAME ..." "Writing $file to partition $SLOT_NAME ...")"
	if ! mtd write "$file" "$SLOT_NAME"; then
		die "$(L "mtd write не отработал. Слот мог остаться в промежуточном состоянии --
       не перезагружайтесь и повторите запись или верните копию:
       sh flash.sh -r $BACKUP_FILE" \
			"mtd write failed. The slot may be half-written -- do not reboot,
       repeat the write or restore the backup:
       sh flash.sh -r $BACKUP_FILE")"
	fi
	if verify_written "$file"; then
		say "$(L 'Проверка чтением:     ' 'Read-back check:      ') $(L 'совпало' 'match') ($(sha_of "$file"))"
		return 0
	fi
	warn "$(L 'обратное чтение не совпало с образом, откатываюсь на резервную копию' \
		'read-back does not match the image, rolling back to the backup')"
	if [ -n "$BACKUP_FILE" ] && [ -r "$BACKUP_FILE" ]; then
		if mtd write "$BACKUP_FILE" "$SLOT_NAME" && verify_written "$BACKUP_FILE"; then
			die "$(L 'запись не удалась, но копия восстановлена и проверена -- роутер загрузится как раньше' \
				'the write failed, but the backup is restored and verified -- the router boots as before')"
		fi
		die "$(L "запись не удалась И откат не подтвердился. НЕ перезагружайтесь,
       повторите: mtd write $BACKUP_FILE $SLOT_NAME" \
			"the write failed AND the rollback is not confirmed. Do NOT reboot,
       repeat: mtd write $BACKUP_FILE $SLOT_NAME")"
	fi
	die "$(L 'запись не удалась, резервной копии нет' 'the write failed and there is no backup')"
}

# Wipe both environment volumes, so the bootloader starts from its built-in
# defaults ("Bad CRC, using default environment").
reset_env() {
	vols=""
	for name in ubootenv ubootenv2; do
		vol=$(ubi_volume "$name") || continue
		vols="$vols $vol"
	done
	if [ -z "$vols" ] || ! command -v ubiupdatevol >/dev/null 2>&1; then
		warn "$(L 'не могу сбросить окружение (нет томов ubootenv или ubiupdatevol).
         Новый загрузчик получит переменные прежнего; сбросьте их в его консоли:
         env default -a; saveenv' \
			'cannot reset the environment (no ubootenv volumes or no ubiupdatevol).
         The new bootloader inherits the old variables; reset them in its console:
         env default -a; saveenv')"
		return 0
	fi
	for vol in $vols; do
		if ! ubiupdatevol "$vol" -t; then
			warn "$(L "не удалось очистить $vol" "cannot wipe $vol")"
			return 0
		fi
	done
	say "$(L '                       очищены:' '                       wiped:')$vols"
}

# Which bootloader wrote the saved environment: http, openwrt or other.
env_owner() {
	all=$(fw_printenv 2>/dev/null || true)
	case "$all" in
	*check_buttons*) echo "openwrt" ;;
	*http_recovery*) echo "http" ;;
	*) echo "other" ;;
	esac
}

# The saved environment replaces the built-in one completely, so it has to fit
# the new bootloader. An invalid environment is left alone: the bootloader then
# uses its defaults. An environment of the other bootloader is wiped.
fix_env() {
	if [ ! -r "$FW_ENV_CONFIG" ]; then
		say "$(L 'Окружение U-Boot:     ' 'U-Boot environment:   ') $(L "$FW_ENV_CONFIG отсутствует, не трогаю" "no $FW_ENV_CONFIG, leaving it")"
		return 0
	fi
	if fw_printenv 2>&1 >/dev/null | grep -qi "bad crc"; then
		say "$(L 'Окружение U-Boot:     ' 'U-Boot environment:   ') $(L 'пустое (Bad CRC) -- загрузчик возьмёт свои значения' 'empty (Bad CRC) -- the bootloader uses its defaults')"
		return 0
	fi
	owner=$(env_owner)
	if [ "$VARIANT" = "openwrt" ]; then
		if [ "$owner" = "openwrt" ]; then
			say "$(L 'Окружение U-Boot:     ' 'U-Boot environment:   ') $(L 'уже от загрузчика OpenWrt' 'already from the OpenWrt bootloader')"
			return 0
		fi
		say "$(L 'Окружение U-Boot:     ' 'U-Boot environment:   ') $(L 'от другого загрузчика, сбрасываю к значениям OpenWrt' 'from another bootloader, resetting to the OpenWrt defaults')"
		reset_env
		return 0
	fi
	if [ "$owner" = "openwrt" ]; then
		say "$(L 'Окружение U-Boot:     ' 'U-Boot environment:   ') $(L 'от загрузчика OpenWrt, сбрасываю к значениям http-uboot' 'from the OpenWrt bootloader, resetting to the http-uboot defaults')"
		reset_env
		return 0
	fi
	cur=$(fw_printenv bootcmd 2>/dev/null | sed -n 's/^bootcmd=//p' | head -n 1)
	want=$(strings -n 3 "$IMAGE" | sed -n 's/^bootcmd=//p' | head -n 1)
	if [ -z "$want" ]; then
		warn "$(L 'не нашёл bootcmd по умолчанию в новом образе, окружение не меняю' \
			'no default bootcmd in the new image, leaving the environment')"
		return 0
	fi
	if [ "$cur" = "$want" ]; then
		say "$(L 'Окружение U-Boot:     ' 'U-Boot environment:   ') $(L "bootcmd уже '$want'" "bootcmd is already '$want'")"
		return 0
	fi
	say "$(L 'Окружение U-Boot:     ' 'U-Boot environment:   ') bootcmd '$cur' -> '$want'"
	if ! fw_setenv bootcmd "$want"; then
		warn "$(L 'не удалось поправить bootcmd: проверьте его вручную после перезагрузки' \
			'cannot set bootcmd: check it by hand after the reboot')"
		return 0
	fi
	got=$(fw_printenv bootcmd 2>/dev/null | sed -n 's/^bootcmd=//p' | head -n 1)
	if [ "$got" != "$want" ]; then
		warn "$(L "bootcmd после записи -- '$got', ожидалось '$want'" \
			"bootcmd after writing is '$got', expected '$want'")"
	fi
}

next_steps() {
	if [ "$VARIANT" = "openwrt" ]; then
		if [ "$UI_LANG" = "ru" ]; then
			cat <<STEPS

Готово. После перезагрузки:
  * система загрузится как обычно, но уже загрузчиком OpenWrt; если том fit
    не загрузится, он возьмёт том recovery;
  * recovery по кнопке: ПК с адресом 192.168.1.10/24 в порт LAN, TFTP-сервер
    раздаёт $OPENWRT_TFTP_FILE
    (из релиза $OPENWRT_RELEASE); включить роутер, через 1-2 с нажать reset
    и держать, пока не загорится синий индикатор (15-20 с); recovery
    поднимется на 192.168.1.1;
  * на UART (115200 8N1) есть меню загрузки: TFTP, recovery, установщик;
  * веб-рекавери http-uboot (http://$RECOVERY_IP) с этим загрузчиком нет,
    upload.sh / upload.ps1 к нему неприменимы.

Откат на прежний загрузчик:
  sh flash.sh -r $BACKUP_FILE
STEPS
		else
			cat <<STEPS

Done. After the reboot:
  * the system boots as usual, now through the OpenWrt bootloader; if the fit
    volume fails to boot, it takes the recovery volume;
  * recovery with the button: PC at 192.168.1.10/24 on a LAN port, a TFTP
    server serving $OPENWRT_TFTP_FILE
    (from release $OPENWRT_RELEASE); power the router on, press reset 1-2 s
    later and hold it until the blue LED lights up (15-20 s); recovery comes
    up at 192.168.1.1;
  * the UART console (115200 8N1) has a boot menu: TFTP, recovery, installer;
  * there is no http-uboot web recovery (http://$RECOVERY_IP) with this
    bootloader, upload.sh / upload.ps1 do not apply.

Roll back to the previous bootloader:
  sh flash.sh -r $BACKUP_FILE
STEPS
		fi
		return 0
	fi
	if [ "$UI_LANG" = "ru" ]; then
		cat <<STEPS

Готово. После перезагрузки:
  * система загрузится как обычно, но уже новым загрузчиком;
  * при неудачной загрузке он сам поднимет веб-рекавери на http://$RECOVERY_IP
    (ПК в порт 10GbE, сетевая карта в режиме DHCP);
  * войти в рекавери принудительно: выключить роутер, включить и держать reset,
    отпустить, когда индикатор состояния сменит ровный красный на "бегущий";
  * прошивку можно заливать тем же рекавери (upload.sh / upload.ps1 с ПК).

Откат на прежний загрузчик:
  sh flash.sh -r $BACKUP_FILE
STEPS
	else
		cat <<STEPS

Done. After the reboot:
  * the system boots as usual, now through the new bootloader;
  * if boot fails, it brings up web recovery at http://$RECOVERY_IP by itself
    (PC on the 10GbE port, network card set to DHCP);
  * to enter recovery on purpose: power the router off, power it on holding
    reset, release when the status LED changes from steady red to "running";
  * firmware can be uploaded through the same recovery (upload.sh / upload.ps1).

Roll back to the previous bootloader:
  sh flash.sh -r $BACKUP_FILE
STEPS
	fi
}

hints_only() {
	if [ "$UI_LANG" = "ru" ]; then
		cat <<STEPS

Ничего не изменено. Возможные дальнейшие шаги:
  * прошить http-uboot с веб-рекавери:  sh flash.sh -u http
  * прошить загрузчик OpenWrt:          sh flash.sh -u openwrt
  * вернуть прежний из копии:           sh flash.sh -r $BACKUP_FILE
STEPS
	else
		cat <<STEPS

Nothing changed. Possible next steps:
  * flash http-uboot with web recovery: sh flash.sh -u http
  * flash the OpenWrt bootloader:       sh flash.sh -u openwrt
  * restore the previous one:           sh flash.sh -r $BACKUP_FILE
STEPS
	fi
}

main() {
	select_language
	if [ "$(id -u)" != "0" ]; then
		die "$(L 'нужны права root' 'root is required')"
	fi
	select_variant
	WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t xr1710g)
	say ""
	say "=== $(L 'XR1710G: прошивка загрузчика' 'XR1710G: bootloader flashing') (flash.sh $SCRIPT_VERSION) ==="
	check_tools
	check_board
	find_slot
	detect_layout
	say "$(L 'Раскладка UBI:        ' 'UBI layout:           ') $LAYOUT_TEXT"
	show_current
	backup_slot

	case "$MODE" in
	hints)
		hints_only
		return 0
		;;
	restore)
		IMAGE="$RESTORE_FILE"
		check_image
		if [ "$VARIANT" = "openwrt" ]; then
			check_openwrt_target
		fi
		confirm "$(L "Записать $IMAGE обратно в слот загрузчика?" "Write $IMAGE back into the bootloader slot?")"
		unlock_slot
		write_slot "$IMAGE"
		fix_env
		;;
	flash)
		check_image
		if [ "$VARIANT" = "openwrt" ]; then
			check_openwrt_target
		fi
		say ""
		say "$(L 'Слот будет перезаписан: 1 МиБ по смещению 0x600000.' 'The slot will be overwritten: 1 MiB at offset 0x600000.')"
		say "$(L 'Прошивка, настройки и данные не затрагиваются.' 'Firmware, settings and data are not touched.')"
		if [ "$VARIANT" = "openwrt" ]; then
			confirm "$(L 'Прошить загрузчик OpenWrt?' 'Flash the OpenWrt bootloader?')"
		else
			confirm "$(L 'Прошить http-uboot?' 'Flash http-uboot?')"
		fi
		unlock_slot
		write_slot "$IMAGE"
		fix_env
		next_steps
		;;
	esac

	if [ "$DO_REBOOT" = 1 ]; then
		say ""
		confirm "$(L 'Перезагрузить роутер сейчас?' 'Reboot the router now?')"
		say "$(L 'Перезагрузка...' 'Rebooting...')"
		cleanup
		sync
		reboot
	else
		say ""
		say "$(L 'Перезагрузка не выполнялась, новый загрузчик начнёт работать после reboot.' \
			'No reboot done, the new bootloader takes over after a reboot.')"
	fi
}

while getopts "u:l:i:m:r:bnyh" opt; do
	case "$opt" in
	u) VARIANT="$OPTARG" ;;
	l) UI_LANG="$OPTARG" ;;
	i) IMAGE="$OPTARG" ;;
	m) MODULE="$OPTARG" ;;
	r)
		MODE="restore"
		RESTORE_FILE="$OPTARG"
		;;
	b)
		MODE="hints"
		DO_REBOOT=0
		;;
	n) DO_REBOOT=0 ;;
	y) ASSUME_YES=1 ;;
	h)
		case "$UI_LANG" in ru | en) ;; *) ASSUME_YES=1 ;; esac
		select_language
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 1
		;;
	esac
done
shift $((OPTIND - 1))

main "$@"
