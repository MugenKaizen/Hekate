#!/usr/bin/env sh

set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

ensure_workflow_git_block() {
  workflow_file="$1"
  workflow_tmp="$TMP_ROOT/workflow.yml.tmp"

  awk '
    BEGIN {
      seen_git = 0
      in_git = 0
      inserted = 0
    }

    function print_block() {
      print "  three_branch_model:               # feature_id: three_branch_model — see .workflow/presets.yml"
      print "    enabled: false"
      print "    branches:"
      print "      main: main                    # production / release"
      print "      stage: stage                  # pre-production / QA"
      print "      dev: dev                      # default integration branch"
      print "    default_working_branch: dev     # branch from which feature branches are cut"
      print "    create_during_bootstrap: true   # if enabled and branches missing, bootstrap creates them locally"
      print "    push_during_bootstrap: false    # never push without asking the user"
    }

    /^git:[[:space:]]*$/ {
      seen_git = 1
      in_git = 1
      print
      next
    }

    {
      if (in_git && /^[^[:space:]]/ && !inserted) {
        print_block()
        inserted = 1
        in_git = 0
      }

      if (in_git && /^  three_branch_model:[[:space:]]*$/) {
        inserted = 1
        in_git = 0
      }

      print
    }

    END {
      if (!seen_git) {
        print ""
        print "git:"
        print_block()
      } else if (in_git && !inserted) {
        print_block()
      }
    }
  ' "$workflow_file" > "$workflow_tmp"

  replace_file_if_changed ".workflow/workflow.yml" "$workflow_tmp"
}

ensure_conventions_branch_fields() {
  conventions_file="$1"
  conventions_tmp="$TMP_ROOT/conventions.yml.tmp"

  awk '
    BEGIN {
      seen_branches = 0
      in_branches = 0
      has_model = 0
      has_flow = 0
    }

    function flush_block() {
      if (!has_model) {
        print "  model: \"\"                # \"\" | three-branch"
      }
      if (!has_flow) {
        print "  flow: \"\"                 # e.g. \"feature → dev → stage → main\""
      }
      in_branches = 0
      has_model = 0
      has_flow = 0
    }

    /^branches:[[:space:]]*$/ {
      seen_branches = 1
      in_branches = 1
      print
      next
    }

    {
      if (in_branches) {
        if ($0 ~ /^  model:/) {
          has_model = 1
        }
        if ($0 ~ /^  flow:/) {
          has_flow = 1
        }
        if ($0 ~ /^[^[:space:]]/) {
          flush_block()
        }
      }

      print
    }

    END {
      if (!seen_branches) {
        print ""
        print "branches:"
        print "  default: \"\"              # main | master | trunk (single-branch repos)"
        print "  style: \"\"                # feature/<slug> | <ticket>-<slug>"
        print "  protected: []"
        print "  model: \"\"                # \"\" | three-branch"
        print "  flow: \"\"                 # e.g. \"feature → dev → stage → main\""
      } else if (in_branches) {
        flush_block()
      }
    }
  ' "$conventions_file" > "$conventions_tmp"

  replace_file_if_changed ".workflow/conventions.yml" "$conventions_tmp"
}

ensure_preset_feature_defaults() {
  presets_file="$1"
  presets_defaults_tmp="$TMP_ROOT/presets.defaults.yml.tmp"
  presets_output_tmp="$TMP_ROOT/presets.yml.tmp"

  awk '
    BEGIN {
      current = ""
      in_features = 0
      has_key = 0
      defaults["fast"] = "false"
      defaults["medium"] = "true"
      defaults["full"] = "true"
    }

    function flush_features() {
      if (in_features && !has_key && current != "") {
        print "      three_branch_model: " defaults[current]
      }
      in_features = 0
      has_key = 0
    }

    {
      if ($0 ~ /^  fast:[[:space:]]*$/) {
        flush_features()
        current = "fast"
        print
        next
      }

      if ($0 ~ /^  medium:[[:space:]]*$/) {
        flush_features()
        current = "medium"
        print
        next
      }

      if ($0 ~ /^  full:[[:space:]]*$/) {
        flush_features()
        current = "full"
        print
        next
      }

      if (current != "" && $0 ~ /^    features:[[:space:]]*$/) {
        flush_features()
        in_features = 1
        print
        next
      }

      if (in_features && $0 ~ /^      three_branch_model:/) {
        has_key = 1
        print
        next
      }

      if (in_features && ($0 ~ /^    [^ ]/ || $0 ~ /^  [^ ]/ || $0 ~ /^[^[:space:]]/)) {
        flush_features()
        print
        next
      }

      print
    }

    END {
      flush_features()
    }
  ' "$presets_file" > "$presets_defaults_tmp"

  if grep -q '^  - id: three_branch_model$' "$presets_defaults_tmp"; then
    replace_file_if_changed ".workflow/presets.yml" "$presets_defaults_tmp"
    return 0
  fi

  {
    cat "$presets_defaults_tmp"
    printf '\n'
    printf '  - id: three_branch_model\n'
    printf '    description: "Maintain main / stage / dev branches in the repo."\n'
    printf '    controls:\n'
    printf '      - "workflow.yml → git.three_branch_model.enabled"\n'
    printf '      - "conventions.yml → branches.model"\n'
    printf '      - "conventions.yml → branches.protected"\n'
    printf '    question: "Maintain a main / stage / dev branch layout in this repo?"\n'
    printf '    defaults: { fast: false, medium: true, full: true }\n'
  } > "$presets_output_tmp"

  replace_file_if_changed ".workflow/presets.yml" "$presets_output_tmp"
}

[ -f "$TARGET/.workflow/workflow.yml" ] && ensure_workflow_git_block "$TARGET/.workflow/workflow.yml"
[ -f "$TARGET/.workflow/conventions.yml" ] && ensure_conventions_branch_fields "$TARGET/.workflow/conventions.yml"
[ -f "$TARGET/.workflow/presets.yml" ] && ensure_preset_feature_defaults "$TARGET/.workflow/presets.yml"
