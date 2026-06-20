#!/system/bin/sh

#################################################################
# microG Universal Installer -- customize.sh
#
# Magisk convention: this script is sourced by module_installer.sh
# (which is sourced by META-INF/.../update-binary) AFTER the module
# files have been extracted to $MODPATH. The root manager exports
# the install environment we rely on, notably:
#   MODPATH    : the module's staging dir under /data/adb/...
#   API        : device API level
#   ARCH / ABI : CPU architecture
#   IS64BIT    : true on 64-bit
#   BOOTMODE   : true when flashed from the manager app
#   KSU / APATCH (when set) : non-Magisk root manager markers
#
# EVENTUAL ROLE (Phase 1):
# This file becomes the generic, data-driven interpreter over
# components.conf (see design spec sections 5.4 and 10). It will:
#   1. source common/log.sh, common/detect.sh, common/place.sh,
#      common/perms.sh, common/cleanup.sh
#   2. iterate each row of components.conf
#   3. place each component's asset under
#      $MODPATH/system/<partition>/{priv-app|framework}/...
#   4. select + place the API-matched permission XML from perms/
#   5. resolve declared conflicts (e.g. FakeStore <-> Phonesky)
#   6. perform declarative stock-GMS removal (REPLACE sentinel)
# It stays a thin interpreter: adding or swapping a component is a
# components.conf data change, not a code change here.
#
# IMPORTANT: module mode never writes real partitions. Everything
# is staged under $MODPATH (on writable /data); the "partition" in
# components.conf is only a path prefix inside the overlay.
#################################################################

# TODO(Phase 1): implement the components.conf interpreter.
# This is an intentional placeholder; the scaffold (Phase 0) only
# establishes the ZIP layout and packaging skeleton. No install
# logic runs yet.
ui_print "- microG Universal Installer scaffold (Phase 0)"
ui_print "- Install logic is implemented in Phase 1; nothing placed yet."
