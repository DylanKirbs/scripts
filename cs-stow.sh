#!/usr/bin/env bash
# Authors:
# Dylan Kirby @DylanKirbs [25853805@sun.ac.za | dylan.kirby.365@gmail.com]
# Alok More @MineCounter [25876864@sun.ac.za]
# set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="0.2.0"

# --- Lockfile Setup --- #
LOCKFILE="/tmp/$SCRIPT_NAME.lock"
cleanup() { 
    rm -f "$LOCKFILE"
    [[ -n "${TEMP_FILES:-}" ]] && rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Configurable Defaults --- #
AUTO_CREATE_DIRS=(".config" ".local" ".vim" ".tmux" ".mozilla", ".config/nvim")
AUTO_CREATE_FILES=(".bashrc" ".vimrc" ".gitconfig" ".tmux.conf") 
DEFAULT_IGNORES=("*.swo" "*.swp" ".*.swo" ".*.swp" ".bash_login" ".bash_profile" ".cache" ".config/dconf" ".config/GNOME*" ".config/gtk*" ".config/ubuntu*" ".config/user*" ".config/xdg*" ".dbus" ".git" ".local/share/Trash" ".pam_environment" ".profile" ".Trash*" ".X*" ".x*")
IGNORE_FILES=(".$SCRIPT_NAME-ignore")
SECOND_LEVEL_DIRS=(".config")

declare -a FILES_TO_SYMLINK

# --- Runtime Flags --- #
DRY_RUN=false
VERBOSE=false
DOTFILES_ONLY=true
FORCE=false
BACKUP=false
UNSTOW=false
MIGRATE=false
SOURCE_DIR=""
TARGET_DIR="$HOME"
IGNORES=()

# --- Logging System --- #
log() {
    local level="$1"; shift
    case "$level" in
        ERROR) echo "[ERROR] $*" >&2 ;;
        WARN)  echo "[WARN]  $*" >&2 ;;
        INFO)  echo "[INFO]  $*" ;;
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
  --migrate                Migrate existing files to source before linking
  --force                  Overwrite conflicts in target
  --backup                 Backup conflicts instead of overwriting
  --unstow                 Remove symlinks instead of creating them

Positional Arguments:
  <source>                 Source directory containing files to stow

Example:
  $SCRIPT_NAME --ignore .git* ~/nfs-home
  # This will create symlinks in \$HOME for all dotfiles in ~/nfs-home, ignoring .git* files/directories.
  
  $SCRIPT_NAME --unstow ~/nfs-home
  # This will remove symlinks from \$HOME that point to files in ~/nfs-home.

Description:
This utility creates symbolic links in the target (defaults to \$HOME) directory for all dotfiles (e.g., .vimrc) and configuration directories (e.g., .config) found in the specified source directory. It also supports ignore patterns, either specified via the command line or defined in ignore files (e.g., .$0-ignore) located in the source or target directories. Additionally, certain directories are automatically created in the source directory before the script runs, such as .config, this caters for the use case of nsf-mounting.
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
            --migrate) MIGRATE=true ;;
            --unstow) UNSTOW=true ;;
            -*)
                log ERROR "Unknown option: $1" >&2
                show_help; exit 1 ;;
            *)
                pos_args+=("$1") ;;
        esac
        shift
    done

    if [[ ${#pos_args[@]} -ne 1 ]]; then
        log ERROR "Expected exactly one positional argument for source directory." >&2
        show_help; exit 1
    fi
    SOURCE_DIR="$(realpath "${pos_args[0]}")"

    [[ -z "$SOURCE_DIR" ]] && { log ERROR "Missing source directory"; show_help; exit 1; }
    [[ ! -d "$TARGET_DIR" ]] && { log ERROR "Target directory does not exist: $TARGET_DIR"; exit 1; }

    # Validate conflicting options
    if $UNSTOW && ($BACKUP || $FORCE); then
        log ERROR "--unstow cannot be used with --backup or --force"
        exit 1
    fi

    IGNORES+=("${DEFAULT_IGNORES[@]}")
    for f in "${IGNORE_FILES[@]}"; do
        [[ -r "$SOURCE_DIR/$f" ]] && mapfile -t lines < "$SOURCE_DIR/$f" && IGNORES+=("${lines[@]}")
        [[ -r "$TARGET_DIR/$f" ]] && mapfile -t lines < "$TARGET_DIR/$f" && IGNORES+=("${lines[@]}")
    done

    log DEBUG "Ignoring: ${IGNORES[*]}"
}

# --- Bootstrap Source --- #
bootstrap_source() {
    log INFO "Bootstrapping source directory: $SOURCE_DIR"

    log DEBUG "Bootstrap Directories: ${AUTO_CREATE_DIRS[*]}"
    log DEBUG "Bootstrap Files: ${AUTO_CREATE_FILES[*]}"

    for d in "${AUTO_CREATE_DIRS[@]}"; do
        [[ -d "$SOURCE_DIR/$d" ]] && continue
        log INFO "[+] mkdir -p $SOURCE_DIR/$d"
        $DRY_RUN || mkdir -p "$SOURCE_DIR/$d"
    done
    for f in "${AUTO_CREATE_FILES[@]}"; do
        [[ -e "$SOURCE_DIR/$f" ]] && continue
        log INFO "[+] touch $SOURCE_DIR/$f"
        $DRY_RUN || touch "$SOURCE_DIR/$f"
    done
}

# --- Collect Files --- #
collect_symlinks() {
    log INFO "Collecting files to symlink from $SOURCE_DIR"

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

                # Store with special marker for second-level directory handling
                all_files+=("$sub:SECOND_LEVEL:$base/$subbase")
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
        # Handle second-level entries differently for deduplication
        if [[ "$file" == *:SECOND_LEVEL:* ]]; then
            rel_path="${file##*:SECOND_LEVEL:}"
        else
            rel_path="${file#$SOURCE_DIR/}"
        fi
        [[ -z "${seen[$rel_path]}" ]] && {
            seen["$rel_path"]=1
            FILES_TO_SYMLINK+=("$file")
        }
    done

    IFS=$'\n' FILES_TO_SYMLINK=($(sort <<<"${FILES_TO_SYMLINK[*]}"))
    unset IFS

    [[ ${#FILES_TO_SYMLINK[@]} -eq 0 ]] && {
        log WARN "No files found to symlink in $SOURCE_DIR"
        exit 0
    }

    log DEBUG "Found ${#FILES_TO_SYMLINK[@]} files to symlink:"
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

    for file_entry in "${FILES_TO_SYMLINK[@]}"; do
        local file link
        
        # Handle second-level directory entries
        if [[ "$file_entry" == *:SECOND_LEVEL:* ]]; then
            file="${file_entry%%:SECOND_LEVEL:*}"
            local target_path="${file_entry##*:SECOND_LEVEL:}"
            link="$TARGET_DIR/$target_path"
        else
            file="$file_entry"
            local base="$(basename "$file")"
            link="$TARGET_DIR/$base"
        fi

        # Validate realpath commands
        local file_real link_real
        file_real="$(realpath "$file" 2>/dev/null)" || {
            log ERROR "Cannot resolve source path: $file"
            ((errors++))
            continue
        }

        # Skip if already correctly linked
        if [[ -L "$link" ]]; then
            link_real="$(realpath "$link" 2>/dev/null)"
            if [[ "$link_real" == "$file_real" ]]; then
                log DEBUG "$link already correctly linked"
                ((linked++))
                continue
            fi
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

# --- Migrate Files --- #
migrate_files() {
    log INFO "Migrating files from $TARGET_DIR to $SOURCE_DIR"

    RSYNC_FLAGS=(
    -rt
    --remove-source-files
    --prune-empty-dirs
    --chmod=ugo=rwX
    --ignore-existing
    --include='*/'
    )

    [[ "$DOTFILES_ONLY" == true ]] && RSYNC_FLAGS+=(--include='.*' --exclude='*')
    [[ "$DOTFILES_ONLY" != true ]] && RSYNC_FLAGS+=(--include='*')

    for pattern in "${IGNORES[@]}"; do
        RSYNC_FLAGS+=(--exclude="$pattern")
    done

    $DRY_RUN && RSYNC_FLAGS+=(--dry-run)
    $VERBOSE && RSYNC_FLAGS+=(--verbose)
    $VERBOSE && echo "[V] Rsync flags: ${RSYNC_FLAGS[*]}"

    rsync "${RSYNC_FLAGS[@]}" "$TARGET_DIR"/ "$SOURCE_DIR"/ || {
        log ERROR "Failed to migrate files from $TARGET_DIR to $SOURCE_DIR"
        exit 1
    }
    log INFO "Migration complete: $TARGET_DIR → $SOURCE_DIR"

}

# --- Backup Function --- #
create_backup() {
    local file="$1"
    local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
    
    log INFO "Backing up: $file → $backup"
    if $DRY_RUN; then
        return 0
    fi
    
    if mv "$file" "$backup"; then
        log INFO "Backup created: $backup"
        return 0
    else
        log ERROR "Failed to create backup: $backup"
        return 1
    fi
}

# --- Restore Backup Function --- #
find_and_restore_backup() {
    local file="$1"
    
    # Find the most recent backup file
    local latest_backup=""
    local latest_timestamp=""
    
    shopt -s nullglob
    local backups=("${file}".bak.*)
    shopt -u nullglob
    for backup in "${backups[@]}"; do
        [[ -e "$backup" ]] || continue
        
        # Extract timestamp from backup filename (format: .bak.YYYYMMDD_HHMMSS)
        local timestamp="${backup##*.bak.}"
        
        # Validate timestamp format
        if [[ "$timestamp" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
            if [[ -z "$latest_timestamp" || "$timestamp" > "$latest_timestamp" ]]; then
                latest_backup="$backup"
                latest_timestamp="$timestamp"
            fi
        fi
    done
    
    if [[ -n "$latest_backup" ]]; then
        log INFO "Restoring backup: $latest_backup → $file"
        if $DRY_RUN; then
            return 0
        fi
        
        if mv "$latest_backup" "$file"; then
            log INFO "Backup restored: $file"
            return 0
        else
            log ERROR "Failed to restore backup: $latest_backup → $file"
            return 1
        fi
    fi
    
    return 1  # No backup found
}

# --- Race Condition - Multiple Instances --- #
acquire_lock() {
    if ! touch "$LOCKFILE" 2>/dev/null; then
        log ERROR "Another instance of $SCRIPT_NAME is already running."
        log ERROR "If you're sure no other instance is running, remove: $LOCKFILE"
        exit 1
    fi
    log DEBUG "Acquired lock: $LOCKFILE"
}

# --- Remove Symlinks (Unstow) --- #
remove_symlinks() {
    log INFO "Removing symlinks from $TARGET_DIR that point to files in $SOURCE_DIR"
    local removed=0 skipped=0 not_found=0 restored=0 errors=0

    for file_entry in "${FILES_TO_SYMLINK[@]}"; do
        local file link
        
        # Handle second-level directory entries
        if [[ "$file_entry" == *:SECOND_LEVEL:* ]]; then
            file="${file_entry%%:SECOND_LEVEL:*}"
            local target_path="${file_entry##*:SECOND_LEVEL:}"
            link="$TARGET_DIR/$target_path"
        else
            file="$file_entry"
            local base="$(basename "$file")"
            link="$TARGET_DIR/$base"
        fi

        # Validate source file exists
        local file_real
        file_real="$(realpath "$file" 2>/dev/null)" || {
            log ERROR "Cannot resolve source path: $file"
            ((errors++))
            continue
        }

        # Check if symlink exists
        if [[ ! -L "$link" ]]; then
            if [[ -e "$link" ]]; then
                log DEBUG "Skipping (not a symlink): $link"
                ((skipped++))
            else
                log DEBUG "Not found: $link"
                ((not_found++))
            fi
            continue
        fi

        # Check if symlink points to our source file
        local link_real
        link_real="$(realpath "$link" 2>/dev/null)"
        if [[ "$link_real" == "$file_real" ]]; then
            log INFO "Removing symlink: $link"
            if $DRY_RUN; then
                ((removed++))
                # Check if backup would be restored in dry run
                local backup_pattern="${link}.bak.*"
                for backup in ${backup_pattern}; do
                    if [[ -e "$backup" ]]; then
                        log INFO "Would restore backup: $backup → $link"
                        break
                    fi
                done
            else
                if rm "$link"; then
                    ((removed++))
                    
                    # Try to restore backup file
                    if find_and_restore_backup "$link"; then
                        ((restored++))
                    fi
                    
                    # Remove empty parent directories (only for second-level dirs)
                    if [[ "$file_entry" == *:SECOND_LEVEL:* ]]; then
                        local parent_dir="$(dirname "$link")"
                        if [[ -d "$parent_dir" ]] && [[ -z "$(ls -A "$parent_dir" 2>/dev/null)" ]]; then
                            log INFO "Removing empty directory: $parent_dir"
                            rmdir "$parent_dir" 2>/dev/null || true
                        fi
                    fi
                else
                    log ERROR "Failed to remove symlink: $link"
                    ((errors++))
                fi
            fi
        else
            log DEBUG "Skipping (points elsewhere): $link → $link_real"
            ((skipped++))
        fi
    done

    echo
    log INFO "Unstow summary$($DRY_RUN && echo " (dry run)"):"
    echo "  Removed symlinks:    $removed"
    echo "  Restored backups:    $restored"
    echo "  Skipped (not ours):  $skipped"
    echo "  Not found:           $not_found"
    [[ $errors -gt 0 ]] && echo "  Errors encountered:  $errors"
    
    # Return non-zero exit code if there were errors
    [[ $errors -eq 0 ]]
}

# --- Main --- #
main() {
    
    acquire_lock

    parse_args "$@"

    $MIGRATE && migrate_files

    bootstrap_source
    collect_symlinks

    if $UNSTOW; then
        remove_symlinks
    else
        create_symlinks
    fi
}

main "$@"
