#!/usr/bin/env sh

set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

status_file="$TARGET/.workflow/status.yml"
status_tmp="$TMP_ROOT/status.yml.tmp"

[ ! -f "$status_file" ] || exit 0

yaml_scalar_nonempty() {
  file="$1"
  key="$2"

  [ -f "$file" ] || return 1
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", value)
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/^[" ]+|[" ]+$/, "", value)
      if (value != "" && value != "null" && value != "[]" && value != "0") {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

yaml_list_nonempty() {
  file="$1"
  key="$2"

  [ -f "$file" ] || return 1
  awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*\\[\\][[:space:]]*($|#)" { exit 1 }
    $0 ~ "^" key ":[[:space:]]*$" { in_list = 1; next }
    in_list && /^[[:space:]]*-[[:space:]]+/ { found = 1; exit }
    in_list && /^[^[:space:]]/ { in_list = 0 }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

read_yaml_value() {
  file="$1"
  key="$2"

  [ -f "$file" ] || return 0
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", value)
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/^[" ]+|[" ]+$/, "", value)
      print value
      exit
    }
  ' "$file"
}

read_block_bool() {
  file="$1"
  block="$2"
  key="$3"
  default="$4"

  [ -f "$file" ] || { printf '%s\n' "$default"; return 0; }
  value="$(awk -v block="$block" -v key="$key" '
    $0 ~ "^[[:space:]]*" block ":[[:space:]]*" { in_block = 1; next }
    in_block && $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", value)
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/[[:space:]]/, "", value)
      print value
      exit
    }
    in_block && /^[[:space:]]*[A-Za-z0-9_]+:/ { exit }
  ' "$file")"

  case "$value" in
    true|false) printf '%s\n' "$value" ;;
    *) printf '%s\n' "$default" ;;
  esac
}

workflow_file="$TARGET/.workflow/workflow.yml"
presets_file="$TARGET/.workflow/presets.yml"
stack_file="$TARGET/.workflow/stack.yml"
architecture_file="$TARGET/.workflow/architecture.yml"
conventions_file="$TARGET/.workflow/conventions.yml"

active_preset="$(read_yaml_value "$presets_file" active_preset)"
[ -n "$active_preset" ] || active_preset="$(read_yaml_value "$workflow_file" preset)"
[ -n "$active_preset" ] || active_preset="null"

required_files_present=true
for required_file in \
  "$stack_file" \
  "$architecture_file" \
  "$conventions_file" \
  "$workflow_file" \
  "$presets_file"
do
  if [ ! -f "$required_file" ]; then
    required_files_present=false
  fi
done

required_fields_filled=true
yaml_scalar_nonempty "$stack_file" project_name || required_fields_filled=false
yaml_scalar_nonempty "$stack_file" project_kind || required_fields_filled=false
yaml_list_nonempty "$stack_file" languages || required_fields_filled=false
yaml_scalar_nonempty "$architecture_file" style || required_fields_filled=false
yaml_list_nonempty "$architecture_file" layers || required_fields_filled=false
yaml_scalar_nonempty "$conventions_file" formatter || required_fields_filled=false
yaml_scalar_nonempty "$conventions_file" files || required_fields_filled=false
yaml_scalar_nonempty "$conventions_file" style || required_fields_filled=false

initialized=false
if [ "$required_files_present" = true ] && [ "$required_fields_filled" = true ] && [ "$active_preset" != null ]; then
  initialized=true
fi

case "$active_preset" in
  fast)
    require_analysis=true
    require_plan=true
    require_options=false
    light_tdd=false
    granular_commits=false
    scope_control=true
    three_branch_model=false
    ;;
  medium)
    require_analysis=true
    require_plan=true
    require_options=true
    light_tdd=false
    granular_commits=true
    scope_control=true
    three_branch_model=true
    ;;
  full)
    require_analysis=true
    require_plan=true
    require_options=true
    light_tdd=true
    granular_commits=true
    scope_control=true
    three_branch_model=true
    ;;
  *)
    require_analysis="$(read_yaml_value "$workflow_file" require_analysis)"
    [ "$require_analysis" = true ] || [ "$require_analysis" = false ] || require_analysis=true
    require_plan="$(read_block_bool "$workflow_file" plan required true)"
    require_options="$(read_block_bool "$workflow_file" require_options enabled true)"
    light_tdd="$(read_block_bool "$workflow_file" light_tdd enabled true)"
    granular_commits="$(read_block_bool "$workflow_file" granular_commits enabled true)"
    scope_control="$(read_block_bool "$workflow_file" scope_control no_unrelated_refactors true)"
    three_branch_model="$(read_block_bool "$workflow_file" three_branch_model enabled false)"
    ;;
esac

cat > "$status_tmp" <<EOF
# Fast pre-flight index for AI agents.
# Read this file at session start instead of loading every .workflow/*.yml.
# It is rewritten after /init-workflow or after deliberate workflow config edits.

schema_version: 1

initialized: $initialized
active_preset: $active_preset

checks:
  required_files_present: $required_files_present
  required_fields_filled: $required_fields_filled

features:
  require_analysis: $require_analysis
  require_plan: $require_plan
  require_options: $require_options
  light_tdd: $light_tdd
  granular_commits: $granular_commits
  scope_control: $scope_control
  three_branch_model: $three_branch_model

lazy_load:
  stack: .workflow/stack.yml
  architecture: .workflow/architecture.yml
  conventions: .workflow/conventions.yml
  workflow_rules: .workflow/workflow.yml
  presets: .workflow/presets.yml
  bootstrap: .workflow/bootstrap.md

required_files:
  - .workflow/stack.yml
  - .workflow/architecture.yml
  - .workflow/conventions.yml
  - .workflow/workflow.yml
  - .workflow/presets.yml

required_non_empty_fields:
  stack.yml: [meta.project_name, meta.project_kind, languages]
  architecture.yml: [style, layers]
  conventions.yml: [code_style.formatter, naming.files, commits.style]

notes:
  - "If initialized is not true, active_preset is null, or any check is false, read .workflow/bootstrap.md."
  - "Do not read stack/architecture/conventions/workflow/presets at startup unless the fast check fails."
EOF

replace_file_if_changed ".workflow/status.yml" "$status_tmp"
