#!/usr/bin/env bash
# Author: Dylan Kirby
# Email: 25853805@sun.ac.za | dylan.kirby.365@gmail.com
# set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="0.1.3"

#Prefvent multiple script instances and race conditons
LOCKFILE="/tmp/$SCRIPT_NAME.lock"
cleanup() { 
    rm -f "$LOCKFILE"
    # +++++++ Clean up any temporary files +++++++
    [[ -n "${TEMP_FILES:-}" ]] && rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Configurable Defaults --- #
AUTO_CREATE_DIRS=(".config" ".local" ".vim" ".tmux" ".mozilla")
AUTO_CREATE_FILES=(".bashrc" ".vimrc" ".gitconfig" ".tmux.conf") 
DEFAULT_IGNORES=(".git" ".Xauthority" ".config/gnome*" ".config/GNOME*" ".config/user*" ".config/ubuntu*" ".config/xdg*" ".config/gtk*" ".config/dconf" ".cache" ".dbus" ".pam_environment" ".bash_profile" ".bash_login" ".xinitrc" ".xsession*" ".Xsession*" ".profile" ".bash_profile" ".local/share/Trash" ".Trash*" "*.swp" "*.swo" ".*.swp" ".*.swo")
IGNORE_FILES=(".$SCRIPT_NAME-ignore")
SECOND_LEVEL_DIRS=(".config")

# --- Runtime Flags --- #
DRY_RUN=false
VERBOSE=false
DOTFILES_ONLY=true
FORCE=false
BACKUP=false
SOURCE_DIR=""
TARGET_DIR="$HOME"
IGNORES=()
# --- Logging System --- #
log() {
    local level="$1"; shift
    case "$level" in
        ERROR) echo "[ERROR] $*" >&2 ;;
        WARN)  echo "[WARN] $*" >&2 ;;
        INFO)  echo "[INFO] $*" ;;
        DEBUG) $VERBOSE && echo "[DEBUG] $*" ;;
    esac
}

# --- Help --- #
show_help() {
cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] <source>

Options:
  -h, --help               Show this help message and exit
  -n, --dry-run            Show actions without executing
  -v, --verbose            Verbose output
  --version                Show script version
  --ignore <pattern>       Glob pattern to ignore (repeatable)
  --allow-non-dotfiles     Include non-dotfiles in symlinks
  --target <dir>           Target directory for links (default: \$HOME)
  --force                  Overwrite conflicts in target
  --backup                 Backup conflicts instead of overwriting

Positional Arguments:
  <source>                 Source directory containing files to stow

Example:
  $SCRIPT_NAME --ignore .git* ~/nfs-home
  # This will create symlinks in \$HOME for all dotfiles in ~/nfs-home, ignoring .git* files/directories.

Description:
This utility creates symbolic links in the target (defaults to \$HOME) directory for all dotfiles (e.g., .vimrc) and configuration directories (e.g., .config) found in the specified source directory. It also supports ignore patterns, either specified via the command line or defined in ignore files (e.g., .$0-ignore) located in the source or target directories. Additionally, certain directories are automatically created in the source directory before the script runs, such as .config, .vscode, and .local/share, this caters for the use case of nsf-mounting.
EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
}

# --- Argument Parsing --- #
parse_args() {

    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi

    pos_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --version) show_version; exit 0 ;;
            -n|--dry-run) DRY_RUN=true ;;
            -v|--verbose) VERBOSE=true ;;
            --force) FORCE=true ;;
            --backup) BACKUP=true ;;
            --allow-non-dotfiles) DOTFILES_ONLY=false ;;
            --ignore) IGNORES+=("$2"); shift ;;
            --ignore=*) IGNORES+=("${1#--ignore=}") ;;
            --target) TARGET_DIR="$(realpath "$2")"; shift ;;
            --target=*) TARGET_DIR="$(realpath "${1#--target=}")" ;;
            -*)
                echo "Unknown option: $1" >&2
                show_help; exit 1 ;;
            *)
                pos_args+=("$1") ;;
        esac
        shift
    done

    if [[ ${#pos_args[@]} -ne 1 ]]; then
        echo "Error: Expected exactly one positional argument for source directory." >&2
        show_help; exit 1
    fi
    SOURCE_DIR="$(realpath "${pos_args[0]}")"

    [[ -z "$SOURCE_DIR" ]] && { echo "Missing source directory"; show_help; exit 1; }
    [[ ! -d "$TARGET_DIR" ]] && { echo "Target directory does not exist: $TARGET_DIR"; exit 1; }

    IGNORES+=("${DEFAULT_IGNORES[@]}")
    for f in "${IGNORE_FILES[@]}"; do
        [[ -r "$SOURCE_DIR/$f" ]] && mapfile -t lines < "$SOURCE_DIR/$f" && IGNORES+=("${lines[@]}")
        [[ -r "$TARGET_DIR/$f" ]] && mapfile -t lines < "$TARGET_DIR/$f" && IGNORES+=("${lines[@]}")
    done

    $VERBOSE && echo "[V] Ignoring: ${IGNORES[*]}"
}

# --- Bootstrap Source --- #
bootstrap_source() {
    echo "Bootstrapping source directory: $SOURCE_DIR"

    $VERBOSE && echo "[V] Bootstrap Directories: ${AUTO_CREATE_DIRS[*]}"
    $VERBOSE && echo "[V] Bootstrap Files: ${AUTO_CREATE_FILES[*]}"

    for d in "${AUTO_CREATE_DIRS[@]}"; do
        [[ -d "$SOURCE_DIR/$d" ]] && continue
        echo "[+] mkdir -p $SOURCE_DIR/$d"
        $DRY_RUN || mkdir -p "$SOURCE_DIR/$d"
    done
    for f in "${AUTO_CREATE_FILES[@]}"; do
        [[ -e "$SOURCE_DIR/$f" ]] && continue
        echo "[+] touch $SOURCE_DIR/$f"
        $DRY_RUN || touch "$SOURCE_DIR/$f"
    done
}

# --- Collect Files --- #
collect_symlinks() {
    echo "Collecting files to symlink from $SOURCE_DIR"

    local all_files=()

    shopt -s dotglob nullglob
    for f in "$SOURCE_DIR"/* "$SOURCE_DIR"/.*; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"

        [[ "$DOTFILES_ONLY" == true && "$base" != .* ]] && continue

        for pattern in "${IGNORES[@]}"; do
            [[ "$base" == $pattern ]] && continue 2
        done

        # If base is in SECOND_LEVEL_DIRS, descend and collect second-level entries
        if [[ -d "$f" && " ${SECOND_LEVEL_DIRS[*]} " =~ " $base " ]]; then
            for sub in "$f"/*; do
                [[ -e "$sub" ]] || continue
                subbase="$(basename "$sub")"

                rel_path="${f#$SOURCE_DIR/}/$subbase"
                for pattern in "${IGNORES[@]}"; do
                  [[ "$subbase" == $pattern || "$rel_path" == $pattern ]] && continue 2
                done

                all_files+=("$sub")
            done
        else
            all_files+=("$f")
        fi
    done
    shopt -u dotglob nullglob

    # Deduplicate and sort
    declare -A seen
    FILES_TO_SYMLINK=()
    for file in "${all_files[@]}"; do
        rel_path="${file#$SOURCE_DIR/}"
        [[ -z "${seen[$rel_path]}" ]] && {
            seen["$rel_path"]=1
            FILES_TO_SYMLINK+=("$file")
        }
    done

    IFS=$'\n' FILES_TO_SYMLINK=($(sort <<<"${FILES_TO_SYMLINK[*]}"))
    unset IFS

    [[ ${#FILES_TO_SYMLINK[@]} -eq 0 ]] && {
        echo "No files found to symlink in $SOURCE_DIR"
        exit 0
    }

    $VERBOSE && echo "[V] Found ${#FILES_TO_SYMLINK[@]} files to symlink:"
    $VERBOSE && printf "  %s\n" "${FILES_TO_SYMLINK[@]}"
}

# --- Create Symlinks with Parent Dir check --- #
create_symlink_with_parents() {
    local source="$1" target="$2"
    local parent_dir="$(dirname "$target")"
    
    # Ensure parent directory exists
    if [[ ! -d "$parent_dir" ]]; then
        log INFO "Creating parent directory: $parent_dir"
        $DRY_RUN || mkdir -p "$parent_dir" || {
            log ERROR "Failed to create parent directory: $parent_dir"
            return 1
        }
    fi
    
    # Check for circular symlinks
    if is_circular_symlink "$source" "$target"; then
        log WARN "Skipping circular symlink: $source → $target"
        return 1
    fi
    
    log INFO "ln -s $source → $target"
    $DRY_RUN || ln -s "$source" "$target" || {
        log ERROR "Failed to create symlink: $source → $target"
        return 1
    }
    
    return 0
}

# --- Create Symlinks --- #
create_symlinks() {
    log INFO "Creating symlinks in $TARGET_DIR for files in $SOURCE_DIR"
    local created=0 skipped=0 linked=0 errors=0

    for file in "${FILES_TO_SYMLINK[@]}"; do
        local base="$(basename "$file")"
        local link="$TARGET_DIR/$base"

        # Skip if already correctly linked
        if [[ -L "$link" && "$(realpath "$link" 2>/dev/null)" == "$(realpath "$file" 2>/dev/null)" ]]; then
            log DEBUG "$link already correctly linked"
            ((linked++))
            continue
        fi

        # Handle conflict
        if [[ -e "$link" || -L "$link" ]]; then
            if $FORCE; then
                log WARN "Removing existing: $link"
                $DRY_RUN || rm -rf "$link" || {
                    log ERROR "Failed to remove existing file: $link"
                    ((errors++))
                    continue
                }
            elif $BACKUP; then
                if ! create_backup "$link"; then
                    ((errors++))
                    continue
                fi
            else
                log WARN "Skipping (exists): $link"
                ((skipped++))
                continue
            fi
        fi

        if create_symlink_with_parents "$file" "$link"; then
            ((created++))
        else
            ((errors++))
        fi
    done

    echo
    log INFO "Summary$($DRY_RUN && echo " (dry run)"):"
    echo "  Linked new:          $created"
    echo "  Already correct:     $linked"
    echo "  Skipped conflicts:   $skipped"
    [[ $errors -gt 0 ]] && echo "  Errors encountered:  $errors"
    
    # Return non-zero exit code if there were errors
    [[ $errors -eq 0 ]]
}

# --- Circular Symlink Detection --- #
is_circular_symlink() {
    local source="$1" target="$2"
    local source_real target_parent_real
    
    source_real="$(realpath "$source" 2>/dev/null)" || return 1
    target_parent_real="$(realpath "$(dirname "$target")" 2>/dev/null)" || return 1
    
    [[ "$source_real" == "$target_parent_real" ]] && return 0
    
    # Check if target would create a loop back to source
    if [[ -L "$target" ]]; then
        local target_real
        target_real="$(realpath "$target" 2>/dev/null)" || return 1
        [[ "$target_real" == "$source_real" ]] && return 0
    fi
    
    return 1
}

# --- Race Condition - Multiple Instances --- #
acquire_lock() {
    if ! mkdir "$LOCKFILE" 2>/dev/null; then
        log ERROR "Another instance of $SCRIPT_NAME is already running."
        log ERROR "If you're sure no other instance is running, remove: $LOCKFILE"
        exit 1
    fi
    log DEBUG "Acquired lock: $LOCKFILE"
}

# --- Main --- #
main() {
    
    acquire_lock

    parse_args "$@"
    bootstrap_source
    collect_symlinks
    create_symlinks
}

main "$@"
