#!/usr/bin/env bash
set -euo pipefail

phase="${1:-}"
[[ $phase == prepare || $phase == verify ]] || {
    echo "Usage: $0 <prepare|verify>" >&2
    exit 2
}

ARTIFACTS="${OMARCHY_ACCEPTANCE_DIR:?Set OMARCHY_ACCEPTANCE_DIR to a persistent artifact directory}"
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
export OMARCHY_PATH
export PATH="$OMARCHY_PATH/bin:$HOME/.local/bin:$PATH"
mkdir -p "$ARTIFACTS"

fail() {
    echo "not ok - $*" | tee "$ARTIFACTS/native-acceptance.failure" >&2
    exit 1
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"; }
for command_name in jq git pacman sha256sum stat journalctl hyprctl omarchy omarchy-shell quickshell qs inotifywait busctl; do
    require_cmd "$command_name"
done

# This is the same SSH/session discovery used by the upstream graphical suite.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
session_ready=0
deadline=$((SECONDS + 120))
while ((SECONDS < deadline)); do
    signature=$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || true)
    export HYPRLAND_INSTANCE_SIGNATURE="$signature"
    if [[ -z ${WAYLAND_DISPLAY:-} ]]; then
        socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-[0-9]*' -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || true)
        [[ -z $socket ]] || export WAYLAND_DISPLAY="$socket"
    fi
    if [[ -n $signature && -n ${WAYLAND_DISPLAY:-} ]] && hyprctl -j monitors >/dev/null 2>&1 && omarchy-shell shell ping >/dev/null 2>&1; then
        session_ready=1
        break
    fi
    sleep 2
done
((session_ready)) || fail "Hyprland/Quickshell session did not become reachable"
if [[ -z ${DISPLAY:-} ]]; then
    display=$(systemctl --user show-environment | sed -n 's/^DISPLAY=//p' | tail -1)
    export DISPLAY="$display"
    export DISPLAY="${DISPLAY:-:0}"
fi
pgrep -u "$(id -u)" -x Hyprland >/dev/null || fail "no real Hyprland process is running"
pgrep -u "$(id -u)" -x quickshell >/dev/null || fail "no real Quickshell process is running"
hyprctl -j monitors | jq -e 'length > 0' >/dev/null || fail "Hyprland has no reachable monitor"

# Plugin discovery and config loading are asynchronous even after IPC ping works.
# Keep the actual list response as evidence; never replace it with a fixture.
wait_for_plugins() {
    local output="$1" filter="$2" deadline=$((SECONDS + 35))
    shift 2
    while ((SECONDS < deadline)); do
        if omarchy plugin list --json >"$output" 2>"$output.stderr" &&
            jq -e "$@" "$filter" "$output" >/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}
wait_for_plugins "$ARTIFACTS/list-json.initial.json" \
    'type == "array" and any(.[]; .id == "omarchy.clock" and .firstParty == true)' ||
    fail "native plugin registry did not discover the built-in clock"

snapshot_package_files() {
    local output="$1" path package owner hash
    : >"$output"
    while IFS= read -r path; do
        [[ -f $path ]] || continue
        package=$(pacman -Qoq -- "$path") || fail "package ownership lookup failed: $path"
        owner=$(stat -c '%u:%g' -- "$path") || fail "owner lookup failed: $path"
        hash=$(sha256sum -- "$path" | awk '{print $1}')
        printf '%s\t%s\t%s\t%s\n' "$path" "$package" "$owner" "$hash" >>"$output"
    done < <(pacman -Ql omarchy | awk '$2 ~ /^\// {print $2}' | sort -u)
    [[ -s $output ]] || fail "omarchy package-owned file snapshot is empty"
    sort -o "$output" "$output"
}

compare_package_files() {
    local current="$ARTIFACTS/package-owned.current.tsv"
    snapshot_package_files "$current"
    cmp -s "$ARTIFACTS/package-owned.before.tsv" "$current" || fail "package-owned hashes or owners changed"
}

wait_for_journal_marker() {
    local marker="$1" deadline=$((SECONDS + 35))
    while (( SECONDS < deadline )); do
        # Read the journal fully before grep: grep -q on a pipe can SIGPIPE
        # journalctl and turn a found marker into failure under pipefail.
        if journalctl --user -b -t omarchy-shell --no-pager -o cat >"$ARTIFACTS/plugin-journal.log" 2>"$ARTIFACTS/plugin-journal.stderr" &&
            grep -Fq -- "$marker" "$ARTIFACTS/plugin-journal.log"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

snapshot_omp_state() {
    local dir
    for dir in "$HOME/.omp" "$HOME/.config/omp"; do
        if [[ -d $dir ]]; then
            find "$dir" -type f -print0 | sort -z | xargs -0 -r sha256sum
        fi
    done
}

verify_skills() {
    local dir skill name link profile
    local -a dirs=(.agents/skills .claude/skills .codex/skills .pi/agent/skills .hermes/skills)
    for profile in "$HOME"/.hermes/profiles/*/; do
        [[ -d $profile ]] || continue
        dirs+=("${profile#"$HOME"/}skills")
    done
    [[ -f "$OMARCHY_PATH/default/agents/skills/omarchy/SKILL.md" ]] || fail "official Omarchy skill source is missing"
    for skill in "$OMARCHY_PATH"/default/agents/skills/*/; do
        skill=${skill%/}
        name=${skill##*/}
        [[ -f "$skill/SKILL.md" ]] || fail "official skill source is missing: $name"
        for dir in "${dirs[@]}"; do
            link="$HOME/$dir/$name"
            [[ -L $link && -f $link/SKILL.md && $(readlink -f "$link") == "$(readlink -f "$skill")" ]] ||
                fail "official skill missing: $dir/$name"
        done
    done
}

if [[ $phase == prepare ]]; then
    rm -f "$ARTIFACTS/native-acceptance.failure"
    run_token="$(date +%s)-$$"
    printf '%s\n' "$(cat /proc/sys/kernel/random/boot_id)" >"$ARTIFACTS/boot-id.before"
    snapshot_package_files "$ARTIFACTS/package-owned.before.tsv"

    source_dir="$ARTIFACTS/native-plugin-source"
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    cat >"$source_dir/manifest.json" <<'JSON'
{"schemaVersion":1,"id":"acceptance.native","name":"Acceptance Native","version":"1.0.0","kinds":["service"],"entryPoints":{"service":"Service.qml"}}
JSON
    cat >"$source_dir/Service.qml" <<'QML'
import QtQuick
Item { Component.onCompleted: console.log("OMARCHY_ACCEPTANCE_NATIVE_PLUGIN MARKER-v1") }
QML
    sed -i "s/MARKER-v1/${run_token}-v1/" "$source_dir/Service.qml"
    git -C "$source_dir" init -q
    git -C "$source_dir" config user.email acceptance@omarchy.invalid
    git -C "$source_dir" config user.name 'Omarchy Acceptance'
    git -C "$source_dir" add manifest.json Service.qml
    git -C "$source_dir" commit -qm fixture

    omarchy plugin validate "$source_dir" >"$ARTIFACTS/plugin-validate.log" 2>&1 || fail "native plugin validate failed"
    omarchy plugin add "$source_dir" --yes --enable >"$ARTIFACTS/plugin-add.log" 2>&1 || fail "native local-git plugin add/enable failed"
    wait_for_plugins "$ARTIFACTS/list-json.added.json" \
        'any(.[]; .id == "acceptance.native" and .enabled == true and .firstParty == false)' ||
        fail "added native plugin is not enabled in live shell"
    marker="OMARCHY_ACCEPTANCE_NATIVE_PLUGIN ${run_token}-v1"
    wait_for_journal_marker "$marker" || fail "native plugin load had no observable journal marker"

    sed -i "s/${run_token}-v1/${run_token}-v2/" "$HOME/.config/omarchy/plugins/acceptance.native/Service.qml"
    changed_marker="OMARCHY_ACCEPTANCE_NATIVE_PLUGIN ${run_token}-v2"
    wait_for_journal_marker "$changed_marker" || fail "native hot reload is unproved: changed fixture marker was absent"
    printf '%s\n' passed >"$ARTIFACTS/plugin-hot-reload.receipt"

    omarchy plugin disable acceptance.native >"$ARTIFACTS/plugin-disable.log" 2>&1
    wait_for_plugins "$ARTIFACTS/list-json.disabled.json" \
        'any(.[]; .id == "acceptance.native" and .enabled == false)' ||
        fail "native plugin disable did not persist in live shell"
    omarchy plugin enable acceptance.native >"$ARTIFACTS/plugin-enable.log" 2>&1
    wait_for_plugins "$ARTIFACTS/list-json.reenabled.json" \
        'any(.[]; .id == "acceptance.native" and .enabled == true)' ||
        fail "native plugin enable did not persist in live shell"
    omarchy plugin remove acceptance.native --yes >"$ARTIFACTS/plugin-remove.log" 2>&1
    wait_for_plugins "$ARTIFACTS/list-json.removed.json" \
        'all(.[]; .id != "acceptance.native")' || fail "native plugin remove left a live plugin"

    omarchy plugin clone omarchy.clock >"$ARTIFACTS/clock-clone.log" 2>&1 || fail "native clock clone failed"
    wait_for_plugins "$ARTIFACTS/list-json.cloned.json" \
        'any(.[]; .firstParty == false and .clonedFrom == "omarchy.clock" and .enabled == true)' ||
        fail "clock clone was not enabled in live shell"
    clock_id=$(jq -er '[.[] | select(.firstParty == false and .clonedFrom == "omarchy.clock")] | if length == 1 then .[0].id else error("expected one clock clone") end' "$ARTIFACTS/list-json.cloned.json")
    clock_dir="$HOME/.config/omarchy/plugins/$clock_id"
    [[ -n $clock_id && -d $clock_dir ]] || fail "clock clone was not placed in user config"
    find "$clock_dir" -type f ! -path '*/.git/*' -print0 | sort -z | xargs -0 sha256sum >"$ARTIFACTS/clock-clone.datahash"
    jq -n --arg id "$clock_id" --arg dir "$clock_dir" --arg hash "$(sha256sum "$ARTIFACTS/clock-clone.datahash" | awk '{print $1}')" \
        --arg boot "$(cat "$ARTIFACTS/boot-id.before")" '{clock_clone_id:$id,clock_clone_dir:$dir,clock_clone_datahash:$hash,boot_id_before:$boot}' >"$ARTIFACTS/native-acceptance.state.json"

    shell_before=$(pgrep -u "$(id -u)" -x quickshell)
    omarchy restart shell >"$ARTIFACTS/shell-restart.log" 2>&1 || fail "native shell restart failed"
    wait_for_plugins "$ARTIFACTS/list-json.restarted.json" \
        'any(.[]; .id == $id and .firstParty == false and .enabled == true)' --arg id "$clock_id" ||
        fail "clone state did not survive shell restart"
    shell_after=$(pgrep -u "$(id -u)" -x quickshell)
    [[ $shell_before != "$shell_after" ]] || fail "Quickshell process did not change on restart"

    mkdir -p "$HOME/.local/bin"
    if [[ -e "$HOME/.local/bin/omp" || -L "$HOME/.local/bin/omp" ]]; then
        mv "$HOME/.local/bin/omp" "$ARTIFACTS/omp-original"
    fi
    restore_omp() {
        rm -f "$HOME/.local/bin/omp"
        if [[ -e "$ARTIFACTS/omp-original" || -L "$ARTIFACTS/omp-original" ]]; then
            mv "$ARTIFACTS/omp-original" "$HOME/.local/bin/omp"
        fi
    }
    trap restore_omp EXIT
    snapshot_omp_state >"$ARTIFACTS/omp-state.before"
    cat >"$HOME/.local/bin/omp" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >>"${OMARCHY_ACCEPTANCE_DIR:?}/omp-receipt.jsonl"
STUB
    chmod 0755 "$HOME/.local/bin/omp"
    export OMARCHY_ACCEPTANCE_DIR="$ARTIFACTS"
    # Pin only this controlled boundary ahead of mise shims/system installs.
    export PATH="$HOME/.local/bin:$PATH"
    [[ $(command -v omp) == "$HOME/.local/bin/omp" ]] || fail "controlled OMP recorder is shadowed"
    : >"$ARTIFACTS/omp-receipt.jsonl"
    omarchy default agent --install omp >"$ARTIFACTS/omp-select.log" 2>&1 || fail "native default-agent selection failed"
    prompt="Omarchy acceptance OMP prompt $(date +%s)"
    omarchy agent prompt --inline "$prompt" >"$ARTIFACTS/omp-prompt.log" 2>&1 || fail "native agent prompt launch failed"
    jq -se --arg prompt "$prompt" '. == [["--auto-approve"], ["--auto-approve", "--", $prompt]]' "$ARTIFACTS/omp-receipt.jsonl" >/dev/null ||
        fail "OMP receipt did not prove native default-agent prompt dispatch"
    jq -n --arg status "controlled user-local recording stub; provider binary proof not claimed" '{status:$status}' >"$ARTIFACTS/omp-boundary.json"
    [[ $(omarchy default agent) == omp ]] || fail "OMP selection was not persisted"
    [[ $(cat "$HOME/.config/omarchy/defaults/agent") == omp ]] || fail "agent selector contains unexpected data"
    snapshot_omp_state >"$ARTIFACTS/omp-state.after"
    cmp -s "$ARTIFACTS/omp-state.before" "$ARTIFACTS/omp-state.after" || fail "agent selection changed OMP credential/config state"
    verify_skills
    compare_package_files
    echo "ok - native prepare passed; owner must reboot and invoke verify"
    exit 0
fi

[[ -f "$ARTIFACTS/native-acceptance.state.json" ]] || fail "prepare state is missing"
before_boot=$(jq -er .boot_id_before "$ARTIFACTS/native-acceptance.state.json")
current_boot=$(cat /proc/sys/kernel/random/boot_id)
[[ $current_boot != "$before_boot" ]] || fail "verify requires a real reboot; boot id did not change"
clock_id=$(jq -er .clock_clone_id "$ARTIFACTS/native-acceptance.state.json")
clock_dir=$(jq -er .clock_clone_dir "$ARTIFACTS/native-acceptance.state.json")
[[ -d $clock_dir ]] || fail "clock clone did not persist in user config"
find "$clock_dir" -type f ! -path '*/.git/*' -print0 | sort -z | xargs -0 sha256sum >"$ARTIFACTS/clock-clone.datahash.after"
after_hash=$(sha256sum "$ARTIFACTS/clock-clone.datahash.after" | awk '{print $1}')
[[ $after_hash == "$(jq -er .clock_clone_datahash "$ARTIFACTS/native-acceptance.state.json")" ]] || fail "clock clone data hash changed across reboot"
wait_for_plugins "$ARTIFACTS/list-json.verify.json" \
    'any(.[]; .id == $id and .firstParty == false and .enabled == true)' --arg id "$clock_id" ||
    fail "clock clone is not enabled after reboot"
omarchy-shell shell ping >/dev/null || fail "native Quickshell IPC is not reachable after reboot"
[[ $(omarchy default agent) == omp ]] || fail "OMP selection did not survive reboot"
verify_skills
compare_package_files
echo "ok - native verify passed; clock clone and package-owned hashes/owners persisted"
