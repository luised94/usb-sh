#!/usr/bin/env bash
# m1-audit.sh -- M1 preflight audit. READ-ONLY: runs three greps, tees to a
# timestamped log. Run on EVERY machine before moving anything.
# Usage: bash m1-audit.sh <usb_mount>     e.g. bash m1-audit.sh /mnt/d
set -u

usb_mount="${1:?usage: bash m1-audit.sh <usb_mount>}"
log="$HOME/m1-audit-$(hostname)-$(date +%Y%m%d-%H%M%S).log"

{
echo "== m1-audit on $(hostname) at $(date) =="
echo "== usb_mount: $usb_mount =="
echo
echo "== grep 1: references to migrating repos under ~/personal_repos =="
echo "== (regex includes both 'finance' and 'finances') =="
grep -rnE "personal_repos/(finances|finance|friction|kbd|lab|tasks)([/\"'[:space:]]|\$)" \
  "$HOME/personal_repos" \
  --exclude-dir={.git,.venv,venv,renv,node_modules,.cache,__pycache__,.Rproj.user,library}
echo "== grep 1 rc: $? (1 = no hits, fine) =="
echo
echo "== grep 2: {HOME}/personal_repos tokens inside usb-sh =="
grep -rn '{HOME}/personal_repos' "$HOME/personal_repos/usb-sh" --exclude-dir=.git
echo "== grep 2 rc: $? =="
echo
echo "== grep 3: personal_repos mentions in live USB confs =="
grep -n 'personal_repos' "$usb_mount"/.usb-projects/*.conf
echo "== grep 3 rc: $? =="
echo
echo "== live conf inventory (record conf name -> local_dir leaf) =="
grep -H '^local_dir=' "$usb_mount"/.usb-projects/*.conf
} 2>&1 | tee "$log"

echo
echo "audit log: $log"
echo "NEXT: disposition every hit as conf-to-update / my_config-assumption /"
echo "dead doc. Anything outside those buckets is a blocker."
