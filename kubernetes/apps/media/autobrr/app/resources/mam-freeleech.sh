#!/bin/sh
# autobrr external filter: exit 0 only if a MyAnonamouse torrent is free for this account.
# Args: {{ .TorrentID }} {{ .Freeleech }} {{ .Cookie }} {{ .Title }}
set -eu

TORRENT_ID="${1:?torrent id required}"
ANNOUNCED_FREE="${2:-false}"
COOKIE="${3:?cookie required}"
TITLE="${4:?title required}"

# VIP announces are freeleech for VIP accounts; no need to ask MAM
[ "${ANNOUNCED_FREE}" = "true" ] && exit 0

# Fresh uploads can take a moment to show up in search, so retry a few times
for _ in 1 2 3; do
    result="$(curl -fsSL --max-time 20 --get \
        --cookie "${COOKIE}" \
        --data-urlencode "tor[text]=${TITLE}" \
        --data-urlencode "tor[searchType]=all" \
        --data-urlencode "tor[searchIn]=torrents" \
        --data-urlencode "tor[srchIn][title]=true" \
        --data-urlencode "perpage=100" \
        "https://www.myanonamouse.net/tor/js/loadSearchJSONbasic.php" \
        | jq -r --arg id "${TORRENT_ID}" '
            [.data[]? | select((.id | tostring) == $id)] | first
            | if . == null then "missing"
              elif ([.free, .personal_freeleech, .fl_vip] | map(tostring) | any(. == "1" or . == "true")) then "free"
              else "paid" end')" || result="error"

    case "${result}" in
        free) exit 0 ;;
        paid) exit 1 ;;
    esac
    sleep 10
done

exit 1
