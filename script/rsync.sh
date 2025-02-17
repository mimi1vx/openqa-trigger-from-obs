#!/bin/bash

set -e
environ=$1

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR/.."

[ -d "$environ" ] || { >&2 echo "No directory found: {$environ}"; exit 1; }

# if lock file exists
if [ -e "$environ/rsync.lock" ] && kill -0 $(cat "$environ/rsync.lock") 2>/dev/null; then
    >&2 echo "Lock file already exists: {$environ/rsync.lock}"
    (exit 1)
fi

trap "rm -f $environ/rsync.lock; exit" INT TERM EXIT
echo $$ > $environ/rsync.lock

[ ! -f rsync.secret ] || export RSYNC_PASSWORD="$(cat rsync.secret)"

failures_count=0

for subfolder in $environ/*/ ; do
    [ -d "$subfolder" ] || subfolder="$environ"

set +e
(
    set -e
    [ -e "$subfolder/read_files.sh" ] || { >&2 echo "No file found: {$subfolder/read_files.sh}"; exit 1; }
    if [ ! -e "$subfolder/print_rsync_iso.sh" ] && [ ! -e "$subfolder/print_rsync_repo.sh" ]; then
        >&2 echo "Neither of files found: {$subfolder/print_rsync_iso.sh} nor {$subfolder/print_rsync_repo.sh}"
        exit 1
    fi

    [ -e "$subfolder/print_openqa.sh" ] || { >&2 echo "No file found: {$subfolder/print_openqa.sh}"; exit 1; }

    # nowhere to log yet as we haven't created $logfolder
    bash -e "$subfolder/read_files.sh"

    if [ -e $subfolder/.run_last ] && [ -z "$(diff --brief $subfolder $subfolder/.run_last | grep '.lst')" ]; then
        >&2 echo "No changes found since last run, skipping {$subfolder}"
        continue
    fi

    if [[ "$environ" == *ToTest* ]]; then
        if [[ "$environ" != *Factory* ]] && [[ "$environ" != *MicroOS* ]]; then
            builds="$(grep -h -o -E 'Build[0-9](\.|[0-9]+)*[0-9]+' $subfolder/*.lst 2>/dev/null)" || :
        else
            # for *Factory* we include base branch for checking Snapshot consistency
            builds="$(grep -h -o -E '20[0-9]{6}' $environ/base/*.lst 2>/dev/null || : ; grep -h -o -E '20[0-9]{6}' $subfolder/*.lst 2>/dev/null)" || :
        fi

        if [ -n "$builds" ] && [ $(echo "$builds" | sort | uniq | wc -l) -gt 1 ]; then
            >&2 echo "Conflicting builds found {$builds}, exiting because of conflict in {$subfolder}"
            exit 0
        fi
    fi

    [ ! -f $subfolder/files_iso.lst ] || version=$(tail -n1 $subfolder/files_iso.lst | grep -h -o -E '[0-9](\.|[0-9]+)*[0-9a-f]+' | tail -n1)
    logdir=$subfolder/.run_$(date +%y%m%d_%H%M%S)
    [ -z $version ] || logdir="$logdir"_"$version"

    mkdir $logdir

    [ ! -e "$subfolder/print_rsync_iso.sh" ] || bash -e "$subfolder/print_rsync_iso.sh" > $logdir/rsync_iso.cmd 2> >(tee $logdir/generate_rsync_iso.err)

    [ ! -e "$subfolder/print_rsync_repo.sh" ] || bash -e "$subfolder/print_rsync_repo.sh" > $logdir/rsync_repo.cmd 2> >(tee $logdir/generate_rsync_repo.err)

    # store state of files for eventual troubleshooting and avoid indefinite openqa retry
    cp $subfolder/*.lst $logdir/
    cp $subfolder/*.sh $logdir/
    # copy eventual status files
    for f in $environ/.* ; do
        [ ! -f "$f" ] || cp $f $logdir/
    done

    # remove symbolic link if exists, because ln -f needs additional permissions for apparmor
    [ ! -L "$subfolder/.run_last" ] || rm "$subfolder/.run_last"
    ln -s -T "$(pwd)/$logdir" $subfolder/.run_last

    [ ! -e "$subfolder/print_openqa.sh" ] || bash -e "$subfolder/print_openqa.sh" 2>$logdir/generate_openqa.err > $logdir/openqa.cmd

    for f in {rsync_iso.cmd,rsync_repo.cmd,openqa.cmd}; do
        fail=0
        bash -xe "$subfolder/.run_last/$f" > "$logdir/$f".log 2>&1 || fail=1
        [ "$fail" -eq 0 ] || break 
    done
    (exit "$fail")
)
    res=$?
    [ "$res" -eq 0 ] || : $((++failure_count))
    [ "$subfolder" != "$environ" ] || break
    [ "$res" -eq 0 ] || {
        >&2 echo "$subfolder exit code: $res ($failure_count failures total so far)"
    }

done

( exit $failure_count )
