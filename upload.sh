#!/bin/sh
# shellcheck shell=dash
#
# XR1710G: upload an image into the http-uboot HTTP recovery from a PC.
# Run it when the router is already in recovery (http://192.168.255.1).
#
#   ./upload.sh                 -- upload the http-uboot bootloader (target uboot)
#   ./upload.sh -t firmware -l 2.0 -f openwrt-...-sysupgrade.itb
#
# Messages are in English or Russian: -L en|ru, $XR1710G_LANG, or a question
# at start-up.
#
set -eu

SCRIPT_VERSION="1.1"
HOST="192.168.255.1"
TARGET="uboot"
LAYOUT="2.0"
IMAGE=""
ASSUME_YES=0
WAIT_SECONDS=180
UI_LANG="${XR1710G_LANG:-}"
SLOT_IMAGE="xr1710g-chainloader-slot.bin"
SLOT_SHA256="deaefed37c13f25eb551d60951cec7077adfd01c6964174d0aa938288d27be30"
SLOT_URL="https://github.com/akorshun/xr1710g-uboot-swap/raw/main/firmware/xr1710g-chainloader-slot.bin"
SLOT_MAX=1048576
WORKDIR=""

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
	if [ -n "$WORKDIR" ]; then
		rm -rf "$WORKDIR"
	fi
	return 0
}
trap cleanup EXIT HUP INT TERM

usage() {
	if [ "$UI_LANG" = "ru" ]; then
		cat <<USAGE
XR1710G: заливка образа в HTTP-рекавери (версия $SCRIPT_VERSION)

Использование: upload.sh [опции]

  -i <адрес>   адрес рекавери, по умолчанию $HOST
  -t <цель>    uboot (по умолчанию) или firmware
  -l <версия>  раскладка UBI для firmware: 2.0 (по умолчанию), 1.5 или 1.0
  -f <файл>    образ; без него берётся firmware/$SLOT_IMAGE
               из репозитория рядом со скриптом или скачивается с GitHub
  -w <сек>     сколько ждать появления рекавери, по умолчанию $WAIT_SECONDS
  -L <язык>    язык сообщений: en или ru (без -L скрипт спросит)
  -y           не спрашивать подтверждение
  -h           эта справка
USAGE
	else
		cat <<USAGE
XR1710G: upload an image into the HTTP recovery (version $SCRIPT_VERSION)

Usage: upload.sh [options]

  -i <address> recovery address, default $HOST
  -t <target>  uboot (default) or firmware
  -l <layout>  UBI layout for firmware: 2.0 (default), 1.5 or 1.0
  -f <file>    image; without it firmware/$SLOT_IMAGE is taken
               from the repository next to the script or downloaded from GitHub
  -w <sec>     how long to wait for the recovery, default $WAIT_SECONDS
  -L <lang>    message language: en or ru (without -L the script asks)
  -y           do not ask for confirmation
  -h           this help
USAGE
	fi
}

json_num() {
	sed -n 's/.*"'"$1"'":[[:space:]]*\([-0-9][0-9]*\).*/\1/p' | head -n 1
}

json_str() {
	sed -n 's/.*"'"$1"'":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# read_answer: one line from stdin if it is a terminal, else from /dev/tty.
read_answer() {
	answer=""
	if [ -t 0 ]; then
		read -r answer || answer=""
	elif (: < /dev/tty) 2>/dev/null; then
		read -r answer < /dev/tty || answer=""
	else
		return 1
	fi
	return 0
}

select_language() {
	case "$UI_LANG" in
	ru | en) return 0 ;;
	*) UI_LANG="" ;;
	esac
	case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
	ru* | RU*) guess="ru" ;;
	*) guess="en" ;;
	esac
	if [ "$ASSUME_YES" = 1 ] || { [ ! -t 0 ] && ! (: < /dev/tty) 2>/dev/null; }; then
		UI_LANG="$guess"
		return 0
	fi
	if [ "$guess" = "ru" ]; then
		default=2
	else
		default=1
	fi
	printf 'Language / Язык:\n  1) English\n  2) Русский\n[%s]: ' "$default"
	read_answer || answer=""
	case "${answer:-$default}" in
	2 | ru | RU) UI_LANG="ru" ;;
	*) UI_LANG="en" ;;
	esac
}

confirm() {
	if [ "$ASSUME_YES" = 1 ]; then
		return 0
	fi
	printf '%s [y/N]: ' "$1"
	if ! read_answer; then
		printf '\n'
		die "$(L 'нет терминала для подтверждения, запустите с -y' 'no terminal to confirm on, run with -y')"
	fi
	case "$answer" in
	y | Y | yes | YES | Yes | да | Да | ДА) return 0 ;;
	esac
	die "$(L 'отменено пользователем' 'cancelled by the user')"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{ print $1 }'
	else
		echo ""
	fi
}

resolve_image() {
	if [ -n "$IMAGE" ]; then
		if [ ! -r "$IMAGE" ]; then
			die "$(L "файл $IMAGE не найден" "file $IMAGE not found")"
		fi
		return 0
	fi
	if [ "$TARGET" != "uboot" ]; then
		die "$(L 'для цели firmware укажите образ через -f' 'for the firmware target pass the image with -f')"
	fi
	script_dir=$(dirname "$0")
	if [ -r "$script_dir/firmware/$SLOT_IMAGE" ]; then
		IMAGE="$script_dir/firmware/$SLOT_IMAGE"
		return 0
	fi
	IMAGE="$WORKDIR/$SLOT_IMAGE"
	say "$(L "Скачиваю $SLOT_IMAGE ..." "Downloading $SLOT_IMAGE ...")"
	if ! curl -fsSL -o "$IMAGE" "$SLOT_URL"; then
		die "$(L "не удалось скачать $SLOT_URL" "cannot download $SLOT_URL")"
	fi
}

check_image() {
	size=$(wc -c < "$IMAGE" | tr -d ' ')
	sum=$(sha256_of "$IMAGE")
	say "$(L 'Образ:                ' 'Image:                ') $IMAGE"
	say "$(L '  размер:             ' '  size:               ') $size $(L 'байт' 'bytes')"
	if [ -n "$sum" ]; then
		say "  sha256:              $sum"
	fi
	if [ "$TARGET" = "uboot" ]; then
		if [ "$size" -gt "$SLOT_MAX" ]; then
			die "$(L 'образ загрузчика больше 1 МиБ, рекавери его отвергнет' \
				'the bootloader image is larger than 1 MiB, the recovery will reject it')"
		fi
		magic=$(dd if="$IMAGE" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d " \n")
		if [ "$magic" != "27051956" ]; then
			die "$(L "это не образ слота: нет legacy-заголовка uImage (magic $magic).
       Нужен xr1710g-chainloader-slot.bin, а не u-boot.bin или *.itb" \
				"this is not a slot image: no legacy uImage header (magic $magic).
       Use xr1710g-chainloader-slot.bin, not u-boot.bin or *.itb")"
		fi
		if [ -n "$sum" ] && [ "$sum" = "$SLOT_SHA256" ]; then
			say "$(L '  проверка:           ' '  check:              ') $(L 'совпадает с xr1710g_260805 из YYH2913/http-uboot' 'matches xr1710g_260805 from YYH2913/http-uboot')"
		elif [ -n "$sum" ]; then
			warn "$(L 'образ не совпадает с известным xr1710g_260805, убедитесь в его происхождении' \
				'the image does not match the known xr1710g_260805, make sure where it comes from')"
		fi
	else
		if [ "$size" -lt 1048576 ]; then
			die "$(L 'образ прошивки меньше 1 МиБ, это не sysupgrade.itb' \
				'the firmware image is smaller than 1 MiB, this is not a sysupgrade.itb')"
		fi
		say "$(L '  раскладка UBI:      ' '  UBI layout:         ') $LAYOUT $(L '(должна совпадать с DTS образа!)' '(must match the DTS of the image!)')"
	fi
}

wait_recovery() {
	say ""
	printf '%s http://%s' "$(L 'Жду рекавери на' 'Waiting for the recovery at')" "$HOST"
	waited=0
	while [ "$waited" -lt "$WAIT_SECONDS" ]; do
		if ABOUT=$(curl -fsS --max-time 3 "http://$HOST/about" 2>/dev/null); then
			printf '\n'
			return 0
		fi
		printf '.'
		sleep 2
		waited=$((waited + 2))
	done
	printf '\n'
	die "$(L "рекавери не ответило за $WAIT_SECONDS с.
       Проверьте: ПК в порту 10GbE, адрес получен по DHCP (192.168.255.2),
       роутер в рекавери (кнопка reset при включении или flash.sh на роутере)" \
		"the recovery did not answer within $WAIT_SECONDS s.
       Check: PC on the 10GbE port, address from DHCP (192.168.255.2),
       router in recovery (reset at power-on, or flash.sh on the router)")"
}

show_recovery() {
	uboot=$(printf '%s' "$ABOUT" | json_str u_boot)
	detected=$(printf '%s' "$ABOUT" | json_str detected_layout)
	UI_BUILD=$(printf '%s' "$ABOUT" | json_str ui_build)
	if [ -n "$uboot" ]; then
		say "$(L 'Рекавери:             ' 'Recovery:             ') $uboot"
	fi
	if [ -n "$detected" ]; then
		say "$(L 'Текущая раскладка:    ' 'Current layout:       ') $detected"
	fi
	if [ -n "$UI_BUILD" ]; then
		say "UI build:              $UI_BUILD"
	fi
}

build_url() {
	url="http://$HOST/upload/$TARGET"
	sep="?"
	if [ -n "$UI_BUILD" ]; then
		url="$url${sep}ui_build=$UI_BUILD"
		sep="&"
	fi
	if [ "$TARGET" = "firmware" ]; then
		url="$url${sep}layout=$LAYOUT"
	fi
	echo "$url"
}

post_image() {
	url=$(build_url)
	say ""
	say "POST $url"
	if curl -fsS --max-time 600 -X POST \
		-H "Content-Type: application/octet-stream" \
		--data-binary "@$IMAGE" "$url" > "$WORKDIR/post.out" 2>"$WORKDIR/post.err"; then
		say "$(L 'Образ принят рекавери.' 'The recovery accepted the image.')"
	else
		rc=$?
		sed 's/^/  /' "$WORKDIR/post.err" >&2 || true
		die "$(L "POST не удался (curl $rc). Флеш-память не изменена, если рекавери
       отвергло образ на проверке; проверьте состояние на http://$HOST" \
			"POST failed (curl $rc). Flash is unchanged if the recovery rejected
       the image during validation; check the state at http://$HOST")"
	fi
	if [ -s "$WORKDIR/post.out" ]; then
		head -c 400 "$WORKDIR/post.out"
		printf '\n'
	fi
}

poll_status() {
	say ""
	say "$(L 'Ход операции:' 'Progress:')"
	last=""
	tries=0
	generation=0
	while [ "$tries" -lt 150 ]; do
		tries=$((tries + 1))
		if ! st=$(curl -fsS --max-time 5 "http://$HOST/status" 2>/dev/null); then
			sleep 2
			continue
		fi
		erase_done=$(printf '%s' "$st" | json_num erase_done)
		erase_total=$(printf '%s' "$st" | json_num erase_total)
		write_done=$(printf '%s' "$st" | json_num write_done)
		write_total=$(printf '%s' "$st" | json_num write_total)
		in_progress=$(printf '%s' "$st" | json_num in_progress)
		ok=$(printf '%s' "$st" | json_num ok)
		err=$(printf '%s' "$st" | json_num error)
		line="  $(L 'стирание' 'erase') ${erase_done:-0}/${erase_total:-0}, $(L 'запись' 'write') ${write_done:-0}/${write_total:-0}"
		if [ "$line" != "$last" ]; then
			say "$line"
			last="$line"
		fi
		if [ "${err:-0}" != "0" ]; then
			stage=$(printf '%s' "$st" | json_str error_stage)
			detail=$(printf '%s' "$st" | json_str validation_detail)
			die "$(L 'рекавери вернуло ошибку' 'the recovery returned an error') (code ${err}, stage '${stage}', detail '${detail}')"
		fi
		if [ "${ok:-0}" = "1" ] && [ "${in_progress:-1}" = "0" ]; then
			generation=$(printf '%s' "$st" | json_num completion_generation)
			say "  $(L 'готово' 'done')"
			break
		fi
		sleep 2
	done
	if [ "${generation:-0}" -gt 0 ]; then
		curl -fsS --max-time 5 "http://$HOST/status-ack/$generation" >/dev/null 2>&1 || true
		say "$(L 'Подтверждение отправлено, роутер перезагружается.' 'Acknowledgement sent, the router is rebooting.')"
	else
		say "$(L 'Роутер перезагрузится сам.' 'The router reboots by itself.')"
	fi
}

while getopts "i:t:l:f:w:L:yh" opt; do
	case "$opt" in
	i) HOST="$OPTARG" ;;
	t) TARGET="$OPTARG" ;;
	l) LAYOUT="$OPTARG" ;;
	f) IMAGE="$OPTARG" ;;
	w) WAIT_SECONDS="$OPTARG" ;;
	L) UI_LANG="$OPTARG" ;;
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

select_language

case "$TARGET" in
uboot | firmware) ;;
*) die "$(L "неизвестная цель '$TARGET', допустимы uboot и firmware" "unknown target '$TARGET', expected uboot or firmware")" ;;
esac
case "$LAYOUT" in
1.0 | 1.5 | 2.0) ;;
*) die "$(L "неизвестная раскладка '$LAYOUT', допустимы 2.0, 1.5 и 1.0" "unknown layout '$LAYOUT', expected 2.0, 1.5 or 1.0")" ;;
esac

if ! command -v curl >/dev/null 2>&1; then
	die "$(L 'нужен curl' 'curl is required')"
fi

WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t xr1710g)
ABOUT=""
UI_BUILD=""

say "=== $(L 'XR1710G: заливка в HTTP-рекавери' 'XR1710G: upload into the HTTP recovery') (upload.sh $SCRIPT_VERSION) ==="
resolve_image
check_image
wait_recovery
show_recovery

if [ "$TARGET" = "uboot" ]; then
	confirm "$(L "Записать этот образ в слот загрузчика (1 МиБ) на $HOST?" "Write this image into the bootloader slot (1 MiB) on $HOST?")"
else
	confirm "$(L "Перезаписать UBI ($LAYOUT) прошивкой на $HOST? Данные будут стёрты!" "Overwrite UBI ($LAYOUT) with the firmware on $HOST? Data will be erased!")"
fi

post_image
poll_status
