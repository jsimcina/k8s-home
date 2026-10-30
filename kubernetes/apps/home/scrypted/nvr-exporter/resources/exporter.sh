#!/bin/sh
# Serves the start time of each Scrypted camera's newest main-stream segment.
# Layout: /NVR/scrypted-<id>/<session>/<chunk>/<segment start ms>.rtsp
set -u

newest_first() {
  # Globs expand oldest first (names are 13-digit epoch ms); print them reversed.
  out=""
  for p in "$@"; do
    [ -e "$p" ] && out="$p $out"
  done
  echo "$out"
}

latest_segment() {
  for session in $(newest_first "$1"/[0-9]*/); do
    for chunk in $(newest_first "$session"[0-9]*/); do
      for seg in $(newest_first "$chunk"[0-9]*.rtsp); do
        seg="${seg##*/}"
        echo "${seg%.rtsp}"
        return
      done
    done
  done
}

# The .txt extension makes httpd send text/plain, which Prometheus requires.
httpd -f -p 9100 -h /www &

while true; do
  now=$(date +%s)
  {
    echo "# HELP scrypted_nvr_last_segment_timestamp_seconds Start time of the newest main-stream recording segment."
    echo "# TYPE scrypted_nvr_last_segment_timestamp_seconds gauge"
    for dir in /NVR/scrypted-*; do
      case "${dir##*/}" in *.*) continue ;; esac
      id="${dir##*/scrypted-}"
      seg=$(latest_segment "$dir")
      [ -n "$seg" ] || continue
      ts=$((seg / 1000))
      # Cameras silent for a week are treated as retired rather than alerting forever.
      [ $((now - ts)) -lt 604800 ] || continue
      name=$(grep -m1 "^$id=" /config/cameras | cut -d= -f2-)
      echo "scrypted_nvr_last_segment_timestamp_seconds{camera_id=\"$id\",camera=\"${name:-$id}\"} $ts"
    done
    echo "# HELP scrypted_nvr_exporter_last_run_timestamp_seconds When the exporter last scanned the NVR share."
    echo "# TYPE scrypted_nvr_exporter_last_run_timestamp_seconds gauge"
    echo "scrypted_nvr_exporter_last_run_timestamp_seconds $now"
  } > /www/metrics.txt.tmp && mv /www/metrics.txt.tmp /www/metrics.txt
  sleep 60
done
