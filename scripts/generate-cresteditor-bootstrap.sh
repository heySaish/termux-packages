#!/usr/bin/env bash
##
##  Generate bootstrap-aarch64.zip from existing prebuilt .deb packages
##

set -euo pipefail

SCRIPT_DIR=$(realpath "$(dirname "$0")")
ROOT_DIR=$(realpath "$SCRIPT_DIR/..")

# shellcheck source=scripts/properties.sh
. "$ROOT_DIR/scripts/properties.sh"

DEB_DIR="${1:-$ROOT_DIR/output}"
OUTPUT_DIR="${2:-$ROOT_DIR}"
ARCH="aarch64"

echo "[*] Using package prefix: $TERMUX_PREFIX"
echo "[*] Reading prebuilt packages from: $DEB_DIR"

if [ ! -d "$DEB_DIR" ] || [ -z "$(ls -A "$DEB_DIR"/*_${ARCH}.deb 2>/dev/null)" ]; then
    echo "[!] Error: No $ARCH .deb packages found in $DEB_DIR"
    exit 1
fi

BOOTSTRAP_TMPDIR=$(mktemp -d "/tmp/cresteditor-bootstrap-tmp.XXXXXX")
trap 'rm -rf "$BOOTSTRAP_TMPDIR"' EXIT

BOOTSTRAP_ROOTFS="$BOOTSTRAP_TMPDIR/rootfs"
TARGET_PREFIX_DIR="$BOOTSTRAP_ROOTFS/$TERMUX_PREFIX"

mkdir -p "$TARGET_PREFIX_DIR"
mkdir -p "$TARGET_PREFIX_DIR/etc"
mkdir -p "$TARGET_PREFIX_DIR/tmp"
mkdir -p "$TARGET_PREFIX_DIR/var/lib/dpkg/info"
mkdir -p "$TARGET_PREFIX_DIR/var/lib/dpkg/updates"
mkdir -p "$TARGET_PREFIX_DIR/var/log/apt"
touch "$TARGET_PREFIX_DIR/var/lib/dpkg/available"
touch "$TARGET_PREFIX_DIR/var/lib/dpkg/status"

# Packages to ignore in minimal bootstrap (static libraries and dev headers to keep bootstrap small and fast)
should_skip_package() {
    local deb_name="$1"
    case "$deb_name" in
        *-static_*|*-dev_*) return 0 ;;
        *) return 1 ;;
    esac
}

echo "[*] Extracting .deb packages into rootfs..."
for deb in "$DEB_DIR"/*_"${ARCH}".deb "$DEB_DIR"/*_all.deb; do
    [ -f "$deb" ] || continue
    deb_filename=$(basename "$deb")

    if should_skip_package "$deb_filename"; then
        echo "[-] Skipping static/dev package: $deb_filename"
        continue
    fi

    echo "[+] Processing: $deb_filename"
    pkg_workdir="$BOOTSTRAP_TMPDIR/pkg_work"
    rm -rf "$pkg_workdir"
    mkdir -p "$pkg_workdir"

    ar x "$deb" --output "$pkg_workdir"

    # 1. Extract data tarball
    if [ -f "$pkg_workdir/data.tar.xz" ]; then
        tar -xf "$pkg_workdir/data.tar.xz" -C "$BOOTSTRAP_ROOTFS"
    elif [ -f "$pkg_workdir/data.tar.gz" ]; then
        tar -xf "$pkg_workdir/data.tar.gz" -C "$BOOTSTRAP_ROOTFS"
    elif [ -f "$pkg_workdir/data.tar.zst" ]; then
        tar --zstd -xf "$pkg_workdir/data.tar.zst" -C "$BOOTSTRAP_ROOTFS"
    fi

    # 2. Extract control tarball
    control_dir="$pkg_workdir/control"
    mkdir -p "$control_dir"
    if [ -f "$pkg_workdir/control.tar.xz" ]; then
        tar -xf "$pkg_workdir/control.tar.xz" -C "$control_dir"
    elif [ -f "$pkg_workdir/control.tar.gz" ]; then
        tar -xf "$pkg_workdir/control.tar.gz" -C "$control_dir"
    elif [ -f "$pkg_workdir/control.tar.zst" ]; then
        tar --zstd -xf "$pkg_workdir/control.tar.zst" -C "$control_dir"
    fi

    # Extract package name from control file
    pkg_name=$(grep -i "^Package:" "$control_dir/control" | awk '{print $2}')

    # Append to dpkg status
    {
        cat "$control_dir/control"
        echo "Status: install ok installed"
        echo ""
    } >> "$TARGET_PREFIX_DIR/var/lib/dpkg/status"

    # Copy maintainer scripts (postinst, prerm, etc) to dpkg info
    for script in postinst postrm preinst prerm conffiles; do
        if [ -f "$control_dir/$script" ]; then
            cp "$control_dir/$script" "$TARGET_PREFIX_DIR/var/lib/dpkg/info/${pkg_name}.${script}"
        fi
    done

    # Generate dpkg .list file
    if [ -f "$pkg_workdir/data.tar.xz" ]; then
        tar -tf "$pkg_workdir/data.tar.xz" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "$TARGET_PREFIX_DIR/var/lib/dpkg/info/${pkg_name}.list"
    elif [ -f "$pkg_workdir/data.tar.gz" ]; then
        tar -tf "$pkg_workdir/data.tar.gz" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "$TARGET_PREFIX_DIR/var/lib/dpkg/info/${pkg_name}.list"
    elif [ -f "$pkg_workdir/data.tar.zst" ]; then
        tar --zstd -tf "$pkg_workdir/data.tar.zst" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "$TARGET_PREFIX_DIR/var/lib/dpkg/info/${pkg_name}.list"
    fi
done

# Add bootstrap second stage scripts
echo "[*] Adding bootstrap second stage scripts..."
mkdir -p "$BOOTSTRAP_ROOTFS/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR"
sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
    -e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}|g" \
    -e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE}|g" \
    -e "s|@TERMUX_PACKAGE_MANAGER@|apt|g" \
    -e "s|@TERMUX_PACKAGE_ARCH@|${ARCH}|g" \
    -e "s|@TERMUX_APP__NAME@|${TERMUX_APP__NAME:-Termux}|g" \
    -e "s|@TERMUX_ENV__S_TERMUX@|${TERMUX_ENV__S_TERMUX:-TERMUX_}|g" \
    "$ROOT_DIR/scripts/bootstrap/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE" \
    > "$BOOTSTRAP_ROOTFS/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE"
chmod 700 "$BOOTSTRAP_ROOTFS/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE"

# Profile fallback
mkdir -p "$TARGET_PREFIX_DIR/etc/profile.d"
sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
    -e "s|@TERMUX__PREFIX__PROFILE_D_DIR@|${TERMUX_PREFIX}/etc/profile.d|g" \
    -e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}|g" \
    -e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE}|g" \
    "$ROOT_DIR/scripts/bootstrap/01-termux-bootstrap-second-stage-fallback.sh" \
    > "$TARGET_PREFIX_DIR/etc/profile.d/01-termux-bootstrap-second-stage-fallback.sh" || true

# Generate SYMLINKS.txt and zip
echo "[*] Creating SYMLINKS.txt and packaging bootstrap archive..."
ZIP_NAME="bootstrap-${ARCH}.zip"

(
    cd "$TARGET_PREFIX_DIR"
    # Read links and write SYMLINKS.txt
    while read -r -d '' link; do
        target=$(readlink "$link")
        echo "${target}←${link}" >> SYMLINKS.txt
        rm -f "$link"
    done < <(find . -type l -print0)

    zip -r9 "$BOOTSTRAP_TMPDIR/$ZIP_NAME" ./*
)

mkdir -p "$OUTPUT_DIR"
mv -f "$BOOTSTRAP_TMPDIR/$ZIP_NAME" "$OUTPUT_DIR/$ZIP_NAME"

echo "[✓] SUCCESS: Created $OUTPUT_DIR/$ZIP_NAME"
ls -lh "$OUTPUT_DIR/$ZIP_NAME"
