#!/usr/bin/env bash
# Author: Dylan Kirby
# Email: 25853805@sun.ac.za | dylan.kirby.365@gmail.com
# set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="0.1.2"

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


# --- Create Symlinks --- #
create_symlinks() {
    echo "Creating symlinks in $TARGET_DIR for files in $SOURCE_DIR"
    local created=0 skipped=0 linked=0

    for file in "${FILES_TO_SYMLINK[@]}"; do
        base="$(basename "$file")"
        link="$TARGET_DIR/$base"

        # Skip if already correctly linked
        if [[ -L "$link" && "$(realpath "$link")" == "$(realpath "$file")" ]]; then
            echo "[=] $link already linked"
            ((linked++))
            continue
        fi

        # Handle conflict
        if [[ -e "$link" || -L "$link" ]]; then
            if $FORCE; then
                echo "[!] Removing existing: $link"
                $DRY_RUN || rm -rf "$link"
            elif $BACKUP; then
                backup="$link.bak"
                echo "[!] Backing up $link → $backup"
                $DRY_RUN || mv "$link" "$backup"
            else
                echo "[!] Skipping (exists): $link"
                ((skipped++))
                continue
            fi
        fi

        echo "[+] ln -s $file → $link"
        $DRY_RUN || ln -s "$file" "$link" || {
            echo "Error creating symlink for $file" >&2
            continue
        }
        ((created++))
    done

    echo -e "\nSummary$($DRY_RUN && echo " (dry run)"):"
    echo "  Linked new:          $created"
    echo "  Already correct:     $linked"
    echo "  Skipped conflicts:   $skipped"
}

# --- Main --- #
main() {
    parse_args "$@"
    bootstrap_source
    collect_symlinks
    create_symlinks
}

main "$@"
