# usb-repos migration walkthrough (M-gate, M1-M8)

Run top to bottom. Every step has: the command, what to expect, how to
verify, and cautions. Canary project is kbd; nothing else moves until the
canary round-trips cleanly.

Scope: finances, friction, kbd, tasks move to ~/personal_repos/usb-repos/.
lab does NOT move (its local_dir is a Windows desktop path, outside
~/personal_repos). Verify the exact live leaf names in step 0 -- note the
finance project's local dir leaf is "finances" (plural) per the reference
conf.

---

## Step 0 -- Preconditions (both machines, before anything moves)

0a. Patches 0001-0014 applied to usb-sh and pulled on BOTH machines.
    The migration depends on C8/C9 (safe.directory before bare-repo reads,
    repair-on-source) and C4 (usb_check token resolution). Do NOT apply
    0015 (reference confs) yet -- the post-M4 drift WARN is your signal
    and 0015 would mask it.

        cd ~/personal_repos/usb-sh && git log --oneline -3
        # expect: feat(scaffold): default local_dir under usb-repos/ at or
        # near the top; chore(configs) must NOT be present yet

0b. Fresh session with the new code, USB connected:

        usb_refresh
        # expect: usb: loaded N project(s): ... including kbd

0c. Inventory the live confs and their exact names/leaves:

        ls <USB_MOUNT>/.usb-projects/
        grep -H '^local_dir=' <USB_MOUNT>/.usb-projects/*.conf

    Record the mapping (conf name -> local_dir leaf). Expected shape:
    kbd.conf -> {HOME}/personal_repos/kbd, finance(.conf?) ->
    {HOME}/personal_repos/finances, etc. If any live conf name or leaf
    differs from the reference confs, STOP and reconcile the C13 patch
    later against reality (references must match live byte-for-byte).

Caution: close editors, tmux panes, and shells whose cwd is inside any of
the four directories. A cwd inside a moved directory leaves that process
on a stale inode and mv on some filesystems will refuse or confuse it.

---

## Step 1 -- M1 preflight audit (ALL machines)

Run the three greps (or bash m1-audit.sh, which runs all three and tees to
a log). Note: the plan's regex used "finance" but the directory is
"finances"; the audit script includes both alternatives.

    grep -rnE "personal_repos/(finances|finance|friction|kbd|lab|tasks)([/\"'[:space:]]|\$)" \
      ~/personal_repos \
      --exclude-dir={.git,.venv,venv,renv,node_modules,.cache,__pycache__,.Rproj.user,library}

    grep -rn '{HOME}/personal_repos' ~/personal_repos/usb-sh --exclude-dir=.git

    grep -n 'personal_repos' <USB_MOUNT>/.usb-projects/*.conf

Expect: hits. That is the point. Disposition EVERY hit into one of three
buckets before proceeding:

  1. conf-to-update       -- a live USB conf path; M4/M7 handles it.
  2. my_config-assumption -- my_config code that globs/paths into
                             ~/personal_repos; the one-level glob already
                             excludes subdirectories, but any hard-coded
                             path to a moving repo must be fixed first.
  3. dead doc             -- historical docs/comments; ignore or clean later.

Anything that fits none of the buckets (a cron job, a symlink target, a
script in another repo) is a blocker: fix it or consciously accept the
breakage before M3.

Caution: grep 2 will hit usb-sh's own docs and the reference confs --
those are bucket 3 and bucket 1 (handled by patch 0015) respectively.

---

## Step 2 -- M2 clean state (machine 1, USB connected)

    usb_commit all && usb_push all

Expect: each project either commits + pushes or reports "nothing to
commit"; final lines "commit all complete: N succeeded, 0 failed" and the
push equivalent. Then verify:

    usb_status

Expect per project: worktree=clean and vs_bare=in-sync (this is the C10
output doing its job as migration instrumentation). If any project shows
"n/a (bare has unfetched commits, run usb_pull)", run usb_pull for it and
re-commit/push until in-sync.

HARD GATE: do not proceed with ANY dirty worktree or non-in-sync project.
The mv itself is safe either way, but a clean pushed state means the bare
repos on the USB are a full recovery point -- worst case you delete the
local dir and usb_clone_all rebuilds it.

---

## Step 3 -- M3+M4 canary move (kbd only)

Either run the data-driven script:

    bash migrate-project.sh kbd kbd <USB_MOUNT>

or by hand:

    mkdir -p ~/personal_repos/usb-repos
    mv ~/personal_repos/kbd ~/personal_repos/usb-repos/kbd
    # edit <USB_MOUNT>/.usb-projects/kbd.conf:
    #   local_dir={HOME}/personal_repos/usb-repos/kbd

Verify the conf edit took:

    grep '^local_dir=' <USB_MOUNT>/.usb-projects/kbd.conf
    # expect: local_dir={HOME}/personal_repos/usb-repos/kbd

Cautions:
- Edit ONLY local_dir. sync_file/sync_dir entries using {LOCAL_DIR}
  follow automatically; entries with hard-coded old paths were caught in
  step 1 bucket 1 -- fix those in the same edit.
- The conf lives on the USB and is shared: the moment you save it,
  machine 2 (if it sources) will warn "project 'kbd' not cloned locally"
  until M8 runs there. Expected, harmless.
- Your current shell still holds the OLD USB_KBD_LOCAL_DIR until the next
  step refreshes it. Do not run usb_* commands between mv and refresh.

---

## Step 4 -- M5 reload and check (canary)

    usb_refresh
    usb_check

Expect from usb_refresh: kbd loads (appears in "loaded N project(s)").
If instead you see "project 'kbd' not cloned locally", the mv and the
conf disagree -- re-check step 3 before anything else.

Expect from usb_check:
- kbd: local_dir=.../usb-repos/kbd, exists=yes; repo_path exists=yes;
  branch matches bare repo.
- ONE drift warning: "WARN kbd.conf has drifted from reference copy".
  This is the SIGNAL, not a failure: the stale reference proves the live
  conf changed and patch 0015 is still pending. Any OTHER new error is a
  real problem -- stop and investigate.

---

## Step 5 -- M6 canary round trip

    touch ~/personal_repos/usb-repos/kbd/migration-canary.txt
    usb_commit kbd
    usb_push kbd
    usb_pull kbd
    usb_status

Expect: commit creates "kbd: sync <timestamp>", push succeeds, pull
reports up to date, and usb_status shows kbd worktree=clean,
vs_bare=in-sync. Then remove the canary file and sync again:

    rm ~/personal_repos/usb-repos/kbd/migration-canary.txt
    usb_commit kbd && usb_push kbd

If ANY of these fails: STOP. The failure mode to suspect first is
safe.directory (fixed by C8/C9 -- confirm the patches are actually in the
sourced usb.sh: type _usb_win_path should print a function).

---

## Step 6 -- M7 remaining projects (machine 1)

Repeat steps 3-5 per project, one at a time, verifying each round trip
before starting the next. Using the script:

    bash migrate-project.sh finances finances /mnt/d   # conf IS finances.conf (m1 audit)
    usb_refresh && usb_check
    # round trip as in step 5, substituting the project name

    bash migrate-project.sh friction friction <USB_MOUNT>
    usb_refresh && usb_check
    # round trip

    bash migrate-project.sh tasks tasks <USB_MOUNT>
    usb_refresh && usb_check
    # round trip

Script arguments are: <local_leaf> <conf_basename_without_.conf>
<usb_mount>. Per the m1 audit, leaf and conf are both "finances". lab is
skipped.

Expect usb_check to accumulate one drift WARN per migrated conf (kbd +
finance + friction + tasks = 4 by the end). Still the signal.

---

## Step 7 -- M8 second machine

    cd ~/personal_repos/usb-sh && git pull        # code first (0001-0014)
    # move USB to machine 2, then in a fresh shell:
    usb_refresh
    # expect: "not cloned locally" warns for all migrated projects --
    # correct: the shared confs now point at usb-repos paths that do not
    # exist here yet.

Local moves are per-machine; confs are already edited, so only the mv:

    mkdir -p ~/personal_repos/usb-repos
    mv ~/personal_repos/kbd      ~/personal_repos/usb-repos/kbd
    mv ~/personal_repos/finances ~/personal_repos/usb-repos/finances
    mv ~/personal_repos/friction ~/personal_repos/usb-repos/friction
    mv ~/personal_repos/tasks    ~/personal_repos/usb-repos/tasks
    usb_refresh
    usb_check
    usb_status

Expect: all projects load, same 4 drift WARNs, worktree/vs_bare sane.
Run one round trip (step 5 pattern) on one project as a smoke test.
Also run the step-1 audit greps here if you have not already.

Caution: if machine 2 has local commits that never reached the USB, the
mv is still safe (git does not care about the path), but reconcile with
usb_pull/usb_commit/usb_push before trusting vs_bare readings.

---

## Step 8 -- Post-gate patches and final verification

Only now:

    cd ~/personal_repos/usb-sh
    git am 0015-*.patch 0016-*.patch     # 0017 (tests), 0018 (doc polish) optional

Patch 0015 also RENAMES finance.conf.reference to finances.conf.reference:
the live conf is finances.conf, so the old name meant the drift check
compared nothing and warned "finance.conf has no USB counterpart" forever.

Then the authoritative copy-verify loop. References must match live confs
byte-for-byte and LIVE WINS -- the patch carries my best-known content, but
your live confs may hold comments or sync entries I could not see:

    cd ~/personal_repos/usb-sh
    for c in finances friction kbd tasks lab; do
      if cmp -s "configs/$c.conf.reference" "/mnt/d/.usb-projects/$c.conf"; then
        echo "ok:   $c"
      else
        echo "SYNC: $c (copying live over reference)"
        cp "/mnt/d/.usb-projects/$c.conf" "configs/$c.conf.reference"
      fi
    done
    cmp -s configs/.usb-manifest.reference /mnt/d/.usb-manifest \
      && echo "ok: manifest" || echo "CHECK: manifest drift (investigate, do not blind-copy)"
    git status --short   # commit any SYNC copies:
    git add configs && git commit -m "chore(configs): sync references to live confs post-migration" || true
    git push

THE migration verification, in a fresh shell (both machines after pull):

    usb_refresh
    usb_check

Expect: "matches reference" for every conf including finances.conf, zero
drift warnings, "all checks passed", rc 0.

Finally, the my_config repo commit (separate repo), which per the audit
now carries TWO changes:
- the one-level glob comment plus the frozen explicit skip in
  pull_all_repos/push-equivalents:
      [[ "$repo_name" == "usb-repos" ]] && continue  # defense in depth
- bash/15_job_hunt.sh: JOB_CONFIG_DIR (line 108) and the comment/usage
  paths (lines 20, 1446) move to
  ${HOME}/personal_repos/usb-repos/kbd/docs/job_applications

## Rollback (any point before step 8)

Per project: mv the directory back, revert the conf's local_dir line,
usb_refresh. The bare repos on the USB were never touched by the
migration; a clean M2 state means even a botched local dir is
recoverable with rm -rf + usb_clone_all.
