#!/bin/bash
#
# check.sh - read-only detector for the WhatsApp for Mac media-duplication bug
#
# Scans WhatsApp's per-chat media folders and reports, for each folder, how
# many files it holds and how many *distinct file sizes* those files have.
# Normal chat media has roughly one distinct size per file. An affected chat
# holds tens of thousands of files that share only a handful of sizes.
#
# Guarantees:
#   * Read-only. Nothing is deleted, moved, modified or written to disk.
#   * Folder names (which contain phone numbers / chat IDs) are never printed.
#     Folders are labelled chat_N, group_N, status_N or other_N instead, so the
#     report is safe to paste publicly.
#
# Usage: ./check.sh [--hash] [MEDIA_DIR]
#        ./check.sh --help
#
# Written for the bash 3.2 and BSD userland that ship with macOS.

set -u

# Fixed locale: '.' as decimal separator and byte-wise sorting on every system.
export LC_ALL=C

DEFAULT_DIR="$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"

# Detection thresholds (overridable through the environment).
# A folder is SUSPICIOUS when it has more than MIN_FILES files AND
# files / distinct-sizes >= MIN_RATIO. Healthy chats sit around 1-2.
MIN_FILES=${MIN_FILES:-1000}
MIN_RATIO=${MIN_RATIO:-20}

TAB=$(printf '\t')

usage() {
	cat <<EOF
Usage: ./check.sh [--hash] [MEDIA_DIR]

Read-only check for the WhatsApp for Mac media-duplication bug.

Arguments:
  MEDIA_DIR   WhatsApp media folder to scan. Default:
              $DEFAULT_DIR_SHOWN

Options:
  --hash      For SUSPICIOUS folders, MD5 every file at the most repeated
              size and report how many distinct hashes there are
              (1 distinct hash = the files are byte-for-byte identical).
  -h, --help  Show this help.

Environment:
  MIN_FILES   Minimum file count before a folder can be flagged (default 1000)
  MIN_RATIO   Minimum files / distinct-sizes ratio to flag (default 20)

Exit status: 0 = nothing suspicious, 1 = at least one SUSPICIOUS folder,
             2 = usage or path error.
EOF
}

die() {
	printf 'check.sh: %s\n' "$*" >&2
	exit 2
}

# Replace a leading $HOME with ~ so error messages never show /Users/<name>.
tilde() {
	case "$1" in
		"$HOME") printf '~' ;;
		"$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
		*) printf '%s' "$1" ;;
	esac
}

DEFAULT_DIR_SHOWN=$(tilde "$DEFAULT_DIR")

# Bytes -> du-style human size (base 1024).
human() {
	awk -v b="$1" 'BEGIN {
		split("B K M G T P", u, " ")
		i = 1
		while (b >= 1024 && i < 6) { b /= 1024; i++ }
		if (i == 1) printf "%dB", b
		else printf "%.1f%s", b, u[i]
	}'
}

is_uint() {
	case "$1" in
		'' | *[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

# --- platform -------------------------------------------------------------

# BSD stat/md5 on macOS; GNU fallbacks only so the script can be tested on Linux.
# NEW_1H uses the file's creation (birth) time on macOS, not its modification
# time: new duplicates were observed with an old modification time.
if [ "$(uname -s)" = Darwin ]; then
	STAT_CMD=(stat -f '%z %B')
	MD5_CMD=(md5 -q)
else
	STAT_CMD=(stat -c '%s %Y')
	MD5_CMD=(md5sum)
fi

# --- arguments ------------------------------------------------------------

DO_HASH=0
MEDIA_DIR=""
while [ $# -gt 0 ]; do
	case "$1" in
		--hash) DO_HASH=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			[ $# -gt 1 ] && die "only one path may be given (see --help)"
			[ $# -eq 1 ] && MEDIA_DIR=$1
			break
			;;
		-*) die "unknown option: $1 (see --help)" ;;
		*)
			[ -n "$MEDIA_DIR" ] && die "only one path may be given (see --help)"
			MEDIA_DIR=$1
			;;
	esac
	shift
done

is_uint "$MIN_FILES" || die "MIN_FILES must be a non-negative integer"
is_uint "$MIN_RATIO" || die "MIN_RATIO must be a non-negative integer"

if [ -z "$MEDIA_DIR" ]; then
	MEDIA_DIR=$DEFAULT_DIR
	PATH_NOTE="default ($DEFAULT_DIR_SHOWN)"
else
	MEDIA_DIR=${MEDIA_DIR%/}
	PATH_NOTE="custom (not shown)"
fi

if [ ! -e "$MEDIA_DIR" ]; then
	die "path not found: $(tilde "$MEDIA_DIR")
  Is the native WhatsApp for Mac app installed and linked?
  If your media lives elsewhere, pass the Media folder as an argument."
fi
[ -d "$MEDIA_DIR" ] || die "not a directory: $(tilde "$MEDIA_DIR")"
if ! ls "$MEDIA_DIR" >/dev/null 2>&1; then
	die "cannot read: $(tilde "$MEDIA_DIR")
  macOS protects other apps' containers. Allow the \"access data from other
  apps\" prompt, or give your terminal Full Disk Access in
  System Settings > Privacy & Security, then run again."
fi

# --- scan -----------------------------------------------------------------

NOW=$(date +%s)
SHOW_PROGRESS=0
[ -t 2 ] && SHOW_PROGRESS=1

# One row per folder, kept in memory only:
# bytes, files, unique sizes, ratio, top size, top-size count, new in 1h, kind, path
rows=""
scanned=0

while IFS= read -r -d '' dir; do
	name=${dir##*/}
	case "$name" in
		*@g.us) kind=group ;;
		*@lid | *@s.whatsapp.net) kind=chat ;;
		*.status | status@broadcast) kind=status ;;
		*) kind=other ;;
	esac

	scanned=$((scanned + 1))
	[ "$SHOW_PROGRESS" -eq 1 ] && printf '\rScanning folder %d...' "$scanned" >&2

	stats=$(find "$dir" -type f -exec "${STAT_CMD[@]}" {} + 2>/dev/null |
		awk -v now="$NOW" '
			{ n++; t += $1; c[$1]++; if (now - $2 <= 3600) r++ }
			END {
				u = 0; mc = 0; ms = 0
				for (s in c) {
					u++
					if (c[s] > mc || (c[s] == mc && s + 0 > ms + 0)) { mc = c[s]; ms = s }
				}
				ratio = (u > 0) ? n / u : 0
				printf "%.0f\t%d\t%d\t%.1f\t%d\t%d\t%d\n", t, n + 0, u, ratio, ms, mc, r + 0
			}')
	rows="${rows}${stats}${TAB}${kind}${TAB}${dir}
"
done < <(find "$MEDIA_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

[ "$SHOW_PROGRESS" -eq 1 ] && printf '\r%40s\r' '' >&2

# --- report ---------------------------------------------------------------

echo "WhatsApp for Mac media-duplication check (read-only)"
echo "Path:  $PATH_NOTE"
echo "Date:  $(date '+%Y-%m-%d')"
echo "Rule:  SUSPICIOUS = more than $MIN_FILES files AND files/unique-sizes >= $MIN_RATIO"
echo

if [ "$scanned" -eq 0 ]; then
	echo "No subfolders found. Nothing to check."
	exit 0
fi

n_chat=0 n_group=0 n_status=0 n_other=0
total_bytes=0 status_bytes=0 flagged=0
details=""

printf '%-10s %8s %9s %11s %9s %7s  %s\n' \
	FOLDER SIZE FILES UNIQ_SIZES RATIO NEW_1H FLAG
printf '%-10s %8s %9s %11s %9s %7s  %s\n' \
	---------- -------- --------- ----------- --------- ------- ----------

while IFS="$TAB" read -r bytes files uniq ratio top_size top_count new1h kind dir; do
	[ -n "$bytes" ] || continue
	case "$kind" in
		chat) n_chat=$((n_chat + 1)); label="chat_$n_chat" ;;
		group) n_group=$((n_group + 1)); label="group_$n_group" ;;
		status) n_status=$((n_status + 1)); label="status_$n_status" ;;
		*) n_other=$((n_other + 1)); label="other_$n_other" ;;
	esac

	total_bytes=$(awk -v a="$total_bytes" -v b="$bytes" 'BEGIN { printf "%.0f", a + b }')
	if [ "$kind" = status ]; then
		status_bytes=$(awk -v a="$status_bytes" -v b="$bytes" 'BEGIN { printf "%.0f", a + b }')
	fi

	flag="-"
	if [ "$files" -gt "$MIN_FILES" ] && [ "$files" -ge $((MIN_RATIO * uniq)) ]; then
		flag="SUSPICIOUS"
		flagged=$((flagged + 1))
		share=$(awk -v a="$top_count" -v b="$files" 'BEGIN { printf "%.1f", 100 * a / b }')
		details="${details}${label}: most repeated size is $top_size bytes ($top_count files, $share% of the folder)
"
		if [ "$DO_HASH" -eq 1 ]; then
			[ "$SHOW_PROGRESS" -eq 1 ] && printf '\rHashing %s...' "$label" >&2
			hashed=$(find "$dir" -type f -size "${top_size}c" -exec "${MD5_CMD[@]}" {} + 2>/dev/null |
				awk '{ print $1 }')
			n_hashed=$(printf '%s\n' "$hashed" | grep -c .)
			n_distinct=$(printf '%s\n' "$hashed" | grep . | sort -u | wc -l | tr -d ' ')
			[ "$SHOW_PROGRESS" -eq 1 ] && printf '\r%40s\r' '' >&2
			if [ "$n_distinct" -eq 1 ]; then
				verdict="byte-for-byte identical"
			else
				verdict="not all identical"
			fi
			details="${details}  --hash: $n_hashed files of $top_size bytes -> $n_distinct distinct MD5 ($verdict)
"
		fi
	fi

	printf '%-10s %8s %9d %11d %9s %7d  %s\n' \
		"$label" "$(human "$bytes")" "$files" "$uniq" "$ratio" "$new1h" "$flag"
done < <(printf '%s' "$rows" | sort -t "$TAB" -k1,1nr)

echo
echo "Folders scanned: $scanned (chats $n_chat, groups $n_group, status $n_status, other $n_other)"
echo "Total size:      $(human "$total_bytes")"
if [ "$n_status" -gt 0 ]; then
	echo "Status folders:  $n_status, total $(human "$status_bytes") (statuses expire after 24h)"
else
	echo "Status folders:  none"
fi
echo "Suspicious:      $flagged folder(s)"

if [ "$flagged" -gt 0 ]; then
	echo
	printf '%s' "$details"
	if [ "$DO_HASH" -eq 0 ]; then
		echo "Tip: run again with --hash to check whether the repeated files are identical."
	fi
	echo
	echo "NEW_1H = files created in the last 60 minutes. A non-zero value on a"
	echo "SUSPICIOUS folder means the duplication is still happening."
	exit 1
fi

exit 0
