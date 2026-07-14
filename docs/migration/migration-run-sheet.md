# MIGRATION RUN-SHEET (definitive order)

State when this sheet starts: patches 0001-0014 applied to usb-sh on
machine 1. Patches 0015-0018 NOT applied. Nothing moved yet.

Legend: [EDIT] manual file edit (sed given where safe), [RUN] command in
your interactive shell, [SCRIPT] provided script, [PATCH] git am,
[VERIFY] expected outcome -- stop if it does not match.

=====================================================================
PHASE A -- pre-move code fixes (machine 1, USB not required)
=====================================================================
Do these in one sitting with Phase C; after A1-A3 the code points at the
NEW paths, so tools touching kbd/friction/tasks are inconsistent until
the moves land.

A1. [EDIT] my_config repo -- one commit, four changes:

    cd ~/personal_repos/my_config

    # (a) job_hunt: kbd path prefix (covers lines 20, 108, 1446)
    sed -i 's|personal_repos/kbd/docs/job_applications|personal_repos/usb-repos/kbd/docs/job_applications|g' \
        bash/15_job_hunt.sh

    # (b) friction: disconnected-USB fallback (line 98)
    sed -i 's|USB_FRICTION_LOCAL_DIR:-$HOME/personal_repos/friction|USB_FRICTION_LOCAL_DIR:-$HOME/personal_repos/usb-repos/friction|' \
        bash/13_friction.sh

    # (c) 11_git_utils.sh: MANUAL. In every function that iterates
    # $repos_root/*/ (pull_all_repos and push/status equivalents), add
    # inside the loop, before any git command:
    #
    #     [[ "$(basename "$repo_dir")" == "usb-repos" ]] && continue  # usb-sh-controlled; see usb-sh docs/design.md
    #
    # (adapt the variable name to each loop). Also add a comment near the
    # repos_root default (~line 82):
    #
    #     # One-level glob is load-bearing: ~/personal_repos/usb-repos/ is
    #     # usb-sh-controlled (one repo, one transport). Do not recurse.

    # (d) tasks env var: append to my_config bash (wherever exports live,
    # e.g. a numbered bash/ file) or ~/.bashrc:
    #
    #     export TASKS_LOCAL_DIR="$HOME/personal_repos/usb-repos/tasks"

    [VERIFY] grep -n 'usb-repos' bash/15_job_hunt.sh bash/13_friction.sh bash/11_git_utils.sh
             # expect hits in all three
    git add -A && git commit -m "fix(paths): usb-repos migration -- job_hunt/friction paths, glob skip, TASKS_LOCAL_DIR"
    git push

A2. [EDIT] explorations repo -- kbd.lua fallback (line 31). No
    KBD_LOCAL_DIR export exists, so the fallback is ACTIVE:

    cd ~/personal_repos/explorations
    sed -i 's|%s/personal_repos/kbd|%s/personal_repos/usb-repos/kbd|' kbd_code/kbd.lua
    [VERIFY] grep -n 'usb-repos' kbd_code/kbd.lua
    git add kbd_code/kbd.lua && git commit -m "fix(kbd): fallback path under usb-repos" && git push

A3. [RUN] confirm tasks.py behavior before its move (Phase D):
    grep -n 'TASKS_LOCAL_DIR' ~/personal_repos/explorations/tasks/tasks.py
    # If it has a hard default besides the env var, fix it like A2.
    # The A1(d) export covers the env-var path either way.

A4. [RUN] push usb-sh so machine 2 can pull 0001-0014:
    cd ~/personal_repos/usb-sh && git push

A5. [RUN] optional last sweep: crontab -l 2>/dev/null | grep personal_repos

=====================================================================
PHASE B -- clean-state gate (machine 1, USB connected, FRESH shell)
=====================================================================
B1. [RUN] exec bash            # pick up A1 edits + patched usb.sh
B2. [RUN] usb_commit all && usb_push all
B3. [RUN] usb_status
    [VERIFY] every project: worktree=clean AND vs_bare=in-sync.
    Any "n/a (bare has unfetched commits...)" -> usb_pull that project,
    re-commit/push, re-check. HARD GATE: do not proceed otherwise.
B4. [VERIFY] usb_check baseline WARN inventory. Expect exactly one
    pre-existing config-drift WARN: "finance.conf has no USB counterpart"
    (misnamed reference; patch 0015 fixes it in Phase F). Note any OTHER
    warns now so you can tell new from old later.

=====================================================================
PHASE C -- canary: kbd (machine 1)
=====================================================================
C1. [RUN] close editors/tmux panes/shells with cwd inside ~/personal_repos/kbd
C2. [SCRIPT] bash migrate-project.sh kbd kbd /mnt/d
    [VERIFY] script prints DONE; conf shows
    local_dir={HOME}/personal_repos/usb-repos/kbd; backup .bak created.
C3. [RUN] usb_refresh
    [VERIFY] kbd in "loaded N project(s)". If "not cloned locally" -> the
    mv and conf disagree; stop and reconcile (rollback line is in the
    script output).
C4. [RUN] usb_check
    [VERIFY] kbd paths exist=yes; WARNs = Phase B4 baseline PLUS exactly
    one new "kbd.conf has drifted from reference copy". The drift WARN is
    the SIGNAL. Any other new error: stop.
C5. [RUN] round trip:
    touch ~/personal_repos/usb-repos/kbd/migration-canary.txt
    usb_commit kbd && usb_push kbd && usb_pull kbd
    usb_status          # kbd: worktree=clean, vs_bare=in-sync
    rm ~/personal_repos/usb-repos/kbd/migration-canary.txt
    usb_commit kbd && usb_push kbd
C6. [VERIFY] canary consumers work: run a job_hunt command (A1a) and a
    kbd.lua-backed binding (A2). Both should hit the new path.

=====================================================================
PHASE D -- remaining projects (machine 1), one at a time
=====================================================================
For each line: run the script, then C3-C5 with the project name.

D1. [SCRIPT] bash migrate-project.sh finances finances /mnt/d
D2. [SCRIPT] bash migrate-project.sh friction friction /mnt/d
    then [VERIFY] a friction command works (13_friction.sh reads
    USB_FRICTION_LOCAL_DIR while connected -- should be the new path).
D3. [SCRIPT] bash migrate-project.sh tasks tasks /mnt/d
    then [VERIFY] the tasks tool reads/writes the new dir (A1d export
    active in a fresh shell; exec bash first).

lab does NOT move. End state usb_check WARNs: baseline finance
no-counterpart + four drift WARNs (kbd finances friction tasks).

=====================================================================
PHASE E -- machine 2
=====================================================================
E1. [RUN] pull code FIRST, before connecting the USB matters:
    cd ~/personal_repos/usb-sh && git pull       # 0001-0014
    cd ~/personal_repos/my_config && git pull    # A1
    cd ~/personal_repos/explorations && git pull # A2
    exec bash
E2. [RUN] run both audits here (m1-audit.sh + the my_config/.bashrc
    grep) and disposition anything machine-2-specific.
E3. [RUN] connect USB; usb_refresh
    [VERIFY] "not cloned locally" warns for kbd/finances/friction/tasks
    -- correct: shared confs already point at usb-repos.
E4. [RUN] local moves (confs already edited; per-machine mv only):
    mkdir -p ~/personal_repos/usb-repos
    mv ~/personal_repos/kbd      ~/personal_repos/usb-repos/kbd
    mv ~/personal_repos/finances ~/personal_repos/usb-repos/finances
    mv ~/personal_repos/friction ~/personal_repos/usb-repos/friction
    mv ~/personal_repos/tasks    ~/personal_repos/usb-repos/tasks
E5. [RUN] usb_refresh; usb_check; usb_status
    [VERIFY] all load; same WARN inventory as end of Phase D; every
    project worktree/vs_bare sane. If any project had local-only commits,
    reconcile with usb_pull/usb_commit/usb_push until in-sync.
E6. [RUN] one round-trip smoke test (C5 pattern, any project).

=====================================================================
PHASE F -- post-gate patches and final verification (machine 1)
=====================================================================
F1. [PATCH] cd ~/personal_repos/usb-sh
    git am 0015-*.patch 0016-*.patch
    # optional: git am 0017-*.patch   (test harnesses)
    #           git am 0018-*.patch   (doc/template examples)
    Note 0015 RENAMES finance.conf.reference -> finances.conf.reference.
F2. [RUN] copy-verify loop -- LIVE WINS byte-for-byte:
    for c in finances friction kbd tasks lab; do
      if cmp -s "configs/$c.conf.reference" "/mnt/d/.usb-projects/$c.conf"; then
        echo "ok:   $c"
      else
        echo "SYNC: $c"; cp "/mnt/d/.usb-projects/$c.conf" "configs/$c.conf.reference"
      fi
    done
    git status --short
    # if any SYNC lines:
    git add configs && git commit -m "chore(configs): sync references to live confs post-migration"
F3. [RUN] git push; on machine 2: git pull
F4. [RUN] THE verification, both machines, fresh shell:
    usb_refresh && usb_check
    [VERIFY] "matches reference" for every conf INCLUDING finances.conf,
    zero drift warnings, "all checks passed", rc 0.
F5. [RUN] cleanup:
    rm /mnt/d/.usb-projects/*.pre-migration.bak
    # optional: remove the m1-audit.sh copy from usb-sh if unwanted

=====================================================================
ROLLBACK (any point before F2)
=====================================================================
Per project: mv the dir back, cp the conf .pre-migration.bak over the
conf, usb_refresh. Bare repos on the USB are never touched; a clean
Phase B means rm -rf + usb_clone_all rebuilds any local dir.
