set -eo pipefail

# Rattler-build will not set the SRC_DIR anymore so we set it through templating
export SRC_DIR="@SRC_DIR@"

pushd $SRC_DIR

# If there is a setup.cfg that contains install-scripts then we should not set it here
INSTALL_SCRIPTS_ARG=""
if [ -f setup.cfg ] && grep -q "install[-_]scripts" setup.cfg; then
    # Remove e.g. ros-humble- from PKG_NAME
    PKG_NAME_SHORT=${PKG_NAME#*ros-@DISTRO@-}
    # Substitute "-" with "_"
    PKG_NAME_SHORT=${PKG_NAME_SHORT//-/_}
    INSTALL_SCRIPTS_ARG="--install-scripts=$PREFIX/lib/$PKG_NAME_SHORT"
    echo "WARNING: setup.cfg not set, will set INSTALL_SCRIPTS_ARG to: $INSTALL_SCRIPTS_ARG"
fi

if [ "@EDITABLE@" = "true" ] && [ -f setup.py ]; then
    # An editable wheel (PEP 660) carries no `data_files`, so on its own it would
    # drop the ament index marker, `package.xml`, launch files and other shared
    # resources. Run the regular install for those, divert its copy of the Python
    # sources to a scratch directory, then let pip install the editable finder.
    SCRATCH_DIR="$(mktemp -d)"
    $PYTHON setup.py install --force --prefix="$PREFIX" --install-lib="$SCRATCH_DIR/lib" $INSTALL_SCRIPTS_ARG --single-version-externally-managed --record="$SCRATCH_DIR/record.txt"

    # Remove build artifacts from setup.py install
    rm -rf *.egg-info 2>/dev/null || true
    rm -rf build/ 2>/dev/null || true

    # The console scripts look up their entry point in the distribution metadata,
    # which now comes from the editable install, so they run the source tree.
    $PYTHON -m pip install --editable . --no-deps --no-build-isolation --no-index --force-reinstall -vvv

    # Package what both steps installed into the prefix: the shared resources and
    # scripts from setup.py, the finder and metadata from pip. When setup.cfg
    # moves the scripts to `lib/<pkg>`, drop the copies pip wrote to `bin`.
    DIST_NAME="$($PYTHON setup.py --name 2>/dev/null | tail -n 1)"
    {
        grep "^$PREFIX/" "$SCRATCH_DIR/record.txt" || true
        $PYTHON -c '
import sys
from importlib.metadata import distribution
from pathlib import Path

prefix = Path(sys.argv[1]).resolve()
drop_bin = sys.argv[3] != ""
bin_dir = prefix / "bin"
dist = distribution(sys.argv[2])
for file in dist.files or []:
    path = Path(dist.locate_file(file)).resolve()
    if not path.is_relative_to(prefix) or not path.exists():
        continue
    if drop_bin and path.parent == bin_dir:
        path.unlink()
        continue
    print(path)
' "$PREFIX" "$DIST_NAME" "$INSTALL_SCRIPTS_ARG"
    } | sort -u > "$RATTLER_BUILD_PACKAGE_FILES"
    rm -rf "$SCRATCH_DIR"
elif [ -n "$INSTALL_SCRIPTS_ARG" ]; then
    # The prefix is reused, so record what this build installed instead of
    # letting rattler-build package the previous build's leftovers as well.
    $PYTHON setup.py install --force --prefix="$PREFIX" --install-lib="$SP_DIR" $INSTALL_SCRIPTS_ARG --single-version-externally-managed --record="$RATTLER_BUILD_PACKAGE_FILES"

    # Remove build artifacts from setup.py install
    rm -rf *.egg-info 2>/dev/null || true
    rm -rf build/ 2>/dev/null || true
else
    # pip uninstalls the previous install before reinstalling, so nothing is left
    # behind and rattler-build can keep deriving the contents from the prefix.
    $PYTHON -m pip install . --no-deps --force-reinstall -vvv
fi
