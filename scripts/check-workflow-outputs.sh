#!/usr/bin/env bash
# Verifies that every ${{ steps.<id>.outputs.<name> }} reference in a workflow can actually resolve.
#
# GitHub Actions expands a reference to an output that the producing step never declares to the
# empty string, with no warning at parse time and no warning at run time. A pin bumped to a
# revision that predates an output therefore fails much later, in whichever consumer first
# validates the value - for the release workflow, after signing, notarization, and reviewer
# approval have already been spent.
#
# Pinned third-party steps are checked against PINNED_ACTION_OUTPUTS, a checked-in record of what
# each action declares at the exact SHA it is pinned to. Changing a pin whose outputs are consumed
# forces that record to be updated in the same change, which is what surfaces a removed output in
# review. Local run: steps are checked against the names they write to $GITHUB_OUTPUT.
#
# Hermetic by default so it is safe to run inside the release gate. --online re-derives every
# expected output set from action.yml at the pinned SHA, so the checked-in record cannot rot.
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the test suite can point the check at fixture workflows that must be rejected.
WORKFLOW_DIRECTORY="${SPACEO_WORKFLOW_DIRECTORY:-$REPOSITORY_ROOT/.github/workflows}"
PINNED_ACTION_OUTPUTS="${SPACEO_PINNED_ACTION_OUTPUTS:-$REPOSITORY_ROOT/.github/pinned-action-outputs.txt}"

mode="offline"
case "${1:-}" in
    "") ;;
    --online) mode="online" ;;
    --print-manifest) mode="print" ;;
    *)
        echo "usage: ${BASH_SOURCE[0]##*/} [--online|--print-manifest]" >&2
        exit 2
        ;;
esac

failures=0

report() {
    echo "workflow output check failed: $*" >&2
    failures=$((failures + 1))
}

# Prints the block of the step carrying `id: <wanted>`. Steps are delimited by the "- " lines that
# open each list entry, so the block ends at the next entry or at the first line that dedents out
# of the steps: list.
step_block() {
    local workflow="$1"
    local wanted="$2"
    awk -v wanted="$wanted" '
        function flush() {
            if (matched) printf "%s", buffer
            buffer = ""
            matched = 0
        }
        /^[ ]*steps:[ ]*$/ { flush(); in_steps = 1; step_indent = -1; next }
        in_steps && match($0, /^[ ]*-[ ]/) && (step_indent == -1 || RLENGTH - 2 == step_indent) {
            flush()
            step_indent = RLENGTH - 2
            collecting = 1
        }
        collecting && /[^ ]/ && match($0, /^[ ]*/) && RLENGTH <= step_indent && !match($0, /^[ ]*-[ ]/) {
            flush()
            collecting = 0
            in_steps = 0
        }
        collecting {
            buffer = buffer $0 "\n"
            if ($0 ~ ("^[ ]*id:[ ]*\"?" wanted "\"?[ ]*$")) matched = 1
        }
        END { flush() }
    ' "$workflow"
}

# Top-level keys of an action.yml outputs: block. Nested description text is indented past the two
# spaces a key sits at, so anchoring on the key indent keeps folded descriptions out of the result.
declared_outputs_of_action_definition() {
    awk '
        /^outputs:[ ]*$/ { in_outputs = 1; next }
        in_outputs && /^[^ #]/ { in_outputs = 0 }
        in_outputs && match($0, /^[ ][ ][A-Za-z0-9_-]+:/) {
            key = substr($0, 3, RLENGTH - 3)
            print key
        }
    '
}

fetch_declared_outputs() {
    local pin="$1"
    local repository="${pin%@*}"
    local revision="${pin##*@}"
    local base="https://raw.githubusercontent.com/$repository/$revision"
    local definition=""
    local candidate
    for candidate in action.yml action.yaml; do
        if definition="$(curl -fsSL --retry 3 --max-time 30 "$base/$candidate" 2>/dev/null)"; then
            printf '%s\n' "$definition" | declared_outputs_of_action_definition | sort
            return 0
        fi
    done
    return 1
}

recorded_outputs_of_pin() {
    local pin="$1"
    [[ -r "$PINNED_ACTION_OUTPUTS" ]] || return 1
    awk -v pin="$pin" '
        $1 == "#" || NF == 0 { next }
        $1 == pin {
            found = 1
            for (i = 2; i <= NF; i++) if ($i != "-") print $i
        }
        END { exit found ? 0 : 1 }
    ' "$PINNED_ACTION_OUTPUTS" | sort
}

workflows=()
while IFS= read -r workflow; do
    workflows+=("$workflow")
done < <(find "$WORKFLOW_DIRECTORY" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)

if (( ${#workflows[@]} == 0 )); then
    echo "workflow output check failed: no workflows found in $WORKFLOW_DIRECTORY" >&2
    exit 1
fi

# Pins whose outputs are consumed somewhere, collected across every workflow.
consumed_pins=()

for workflow in "${workflows[@]}"; do
    relative_workflow="${workflow#"$REPOSITORY_ROOT"/}"

    # An unpinned action can change under the repository without review, which is the same silent
    # substitution this check exists to prevent.
    while IFS= read -r reference; do
        [[ -n "$reference" ]] || continue
        if [[ ! "$reference" =~ ^[^@]+@[0-9a-f]{40}$ ]]; then
            report "$relative_workflow uses $reference, which is not pinned to a full commit SHA"
        fi
    done < <(awk 'match($0, /^[ ]*(-[ ]+)?uses:[ ]*/) { rest = substr($0, RLENGTH + 1); sub(/[ \t].*$/, "", rest); print rest }' "$workflow" | sort -u)

    while IFS= read -r reference; do
        [[ -n "$reference" ]] || continue
        step_id="${reference#steps.}"
        step_id="${step_id%%.outputs.*}"
        output_name="${reference##*.outputs.}"

        block="$(step_block "$workflow" "$step_id")"
        if [[ -z "$block" ]]; then
            report "$relative_workflow references $reference but declares no step with id: $step_id"
            continue
        fi

        pin="$(awk 'match($0, /^[ ]*(-[ ]+)?uses:[ ]*/) { rest = substr($0, RLENGTH + 1); sub(/[ \t].*$/, "", rest); print rest; exit }' <<<"$block")"
        if [[ -z "$pin" ]]; then
            # A local run: step owns its outputs, so the check is that it writes the name at all.
            if ! grep -Eq "(^|[^A-Za-z0-9_-])${output_name}=" <<<"$block"; then
                report "$relative_workflow references $reference but step $step_id never writes ${output_name}= to \$GITHUB_OUTPUT"
            fi
            continue
        fi

        consumed_pins+=("$pin")

        if ! recorded="$(recorded_outputs_of_pin "$pin")"; then
            report "$relative_workflow consumes outputs of $pin, which has no entry in ${PINNED_ACTION_OUTPUTS#"$REPOSITORY_ROOT"/}"
            continue
        fi
        if ! grep -Fxq "$output_name" <<<"$recorded"; then
            report "$relative_workflow references $reference, but $pin declares no $output_name output (it would expand to the empty string)"
        fi
    done < <(grep -Eo 'steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+' "$workflow" | sort -u)
done

unique_consumed_pins=()
while IFS= read -r pin; do
    [[ -n "$pin" ]] && unique_consumed_pins+=("$pin")
done < <(printf '%s\n' "${consumed_pins[@]:-}" | sort -u)

if [[ "$mode" == "print" ]]; then
    echo "# Outputs declared by each pinned action whose outputs a workflow consumes."
    echo "# Regenerate with: bash scripts/check-workflow-outputs.sh --print-manifest"
    for pin in "${unique_consumed_pins[@]:-}"; do
        if ! declared="$(fetch_declared_outputs "$pin")"; then
            echo "could not fetch the action definition for $pin" >&2
            exit 1
        fi
        echo "$pin $(tr '\n' ' ' <<<"$declared" | sed -E 's/ +$//')"
    done
    exit 0
fi

if [[ "$mode" == "online" ]]; then
    for pin in "${unique_consumed_pins[@]:-}"; do
        if ! declared="$(fetch_declared_outputs "$pin")"; then
            report "could not fetch the action definition for $pin"
            continue
        fi
        recorded="$(recorded_outputs_of_pin "$pin" || true)"
        if [[ "$declared" != "$recorded" ]]; then
            report "$pin declares [$(tr '\n' ' ' <<<"$declared")] but ${PINNED_ACTION_OUTPUTS#"$REPOSITORY_ROOT"/} records [$(tr '\n' ' ' <<<"$recorded")]"
        fi
    done
fi

if (( failures > 0 )); then
    echo "workflow output check failed with $failures problem(s)" >&2
    exit 1
fi

echo "workflow output references verified ($mode)"
