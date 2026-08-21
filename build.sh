#!/usr/bin/env bash
# Build, run and install NielsNetBar — the menu bar network throughput monitor.
#
#   ./build.sh              debug build → .build/debug/NielsNetBar
#   ./build.sh run [args]   debug build as dist/debug/NielsNetBar.app, (re)launch it detached.
#                           args go to the app, e.g. --hz 5. Add --fg to run in the foreground
#                           instead (logs in this terminal, Ctrl-C quits).
#   ./build.sh stop         quit every running NielsNetBar (dev or installed)
#   ./build.sh app          release build → dist/NielsNetBar.app (ad-hoc signed, icon baked in)
#   ./build.sh install      release build → /Applications/NielsNetBar.app (replacing any older
#                           copy), launch it, and register it to launch at login
#   ./build.sh uninstall    unregister the login item, quit, delete /Applications/NielsNetBar.app
#                           and the saved preferences
#   ./build.sh status       running? installed? login item?
#   ./build.sh icon         re-render docs/icon.png from Sources/NielsNetBar/AppIcon.swift
#   ./build.sh screenshot   re-render docs/screenshot.png (opens the menu, captures it)
#   ./build.sh clean        remove build products
set -euo pipefail
cd "$(dirname "$0")"

NAME=NielsNetBar
BUNDLE_ID=com.njoubert.nielsnetbar
VERSION=1.0
INSTALL_DIR=/Applications
INSTALLED="$INSTALL_DIR/$NAME.app"
DEV_APP="dist/debug/$NAME.app"
REL_APP="dist/$NAME.app"

# --- helpers -----------------------------------------------------------------------------

dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
say()  { printf '%s%s%s\n' "$green" "$*" "$reset"; }
note() { printf '%s%s%s\n' "$dim" "$*" "$reset"; }
warn() { printf '%s%s%s\n' "$yellow" "$*" "$reset" >&2; }

# Assemble a .app around a built binary: Info.plist, icon, ad-hoc signature.
#   make_bundle <config: debug|release> <out.app>
make_bundle() {
  local config=$1 app=$2 bin=".build/$1/$NAME"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/$NAME"

  # The icon is drawn in code; render it to an .iconset and let iconutil pack it.
  local iconset="dist/$config-AppIcon.iconset"
  "$bin" --render-iconset "$iconset" >/dev/null
  iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
  rm -rf "$iconset"

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>macOS only reveals the name of the Wi-Fi network (SSID) to apps with Location access. NielsNetBar uses it for nothing else and never reads your location.</string>
  <key>NSLocationUsageDescription</key>
  <string>macOS only reveals the name of the Wi-Fi network (SSID) to apps with Location access. NielsNetBar uses it for nothing else and never reads your location.</string>
</dict></plist>
PLIST
  plutil -convert xml1 -o /dev/null "$app/Contents/Info.plist"   # validate (plutil -lint misparses here)
  codesign --force --sign - --identifier "$BUNDLE_ID" "$app" >/dev/null 2>&1 || warn "codesign failed (continuing unsigned)"
  note "bundled $app"
}

# Quit every running copy and wait for it to go away.
stop_all() {
  if pgrep -x "$NAME" >/dev/null; then
    pkill -x "$NAME" || true
    for _ in $(seq 1 30); do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
    pgrep -x "$NAME" >/dev/null && { warn "still running, killing"; pkill -9 -x "$NAME" || true; sleep 0.3; }
    say "stopped $NAME"
  else
    note "$NAME is not running"
  fi
}

# --- commands ----------------------------------------------------------------------------

cmd="${1:-build}"
[ $# -gt 0 ] && shift

case "$cmd" in
  build)
    swift build
    say "ok → .build/debug/$NAME"
    ;;

  run)
    fg=0; args=()
    for a in "$@"; do [ "$a" = "--fg" ] && fg=1 || args+=("$a"); done
    swift build
    make_bundle debug "$DEV_APP"
    stop_all
    if [ $fg = 1 ]; then
      exec "$DEV_APP/Contents/MacOS/$NAME" "${args[@]+"${args[@]}"}"
    fi
    open -n "$DEV_APP" --args "${args[@]+"${args[@]}"}"
    say "launched $DEV_APP   (./build.sh stop to quit, ./build.sh run --fg for logs)"
    ;;

  stop)
    stop_all
    [ -e "$INSTALLED" ] && note "the installed copy can be restarted with: open -a $NAME" || true
    ;;

  app)
    swift build -c release
    make_bundle release "$REL_APP"
    say "built $REL_APP"
    ;;

  install)
    swift build -c release
    make_bundle release "$REL_APP"
    stop_all
    if [ -e "$INSTALLED" ]; then
      note "replacing $INSTALLED"
      rm -rf "$INSTALLED"
    fi
    ditto "$REL_APP" "$INSTALLED"
    # SMAppService registration is done by the app itself, for the bundle it runs from —
    # so launch the installed copy and have it register.
    open -n "$INSTALLED" --args --enable-login-item
    sleep 1.5
    say "installed $INSTALLED"
    note "login item: $("$INSTALLED/Contents/MacOS/$NAME" --login-item-status)"
    note "It is running now and will start at login. Toggle that in the menu or in System Settings › General › Login Items."
    ;;

  uninstall)
    if [ -e "$INSTALLED" ]; then
      stop_all
      # Unregister from the installed bundle before it disappears, or Login Items keeps a ghost.
      "$INSTALLED/Contents/MacOS/$NAME" --disable-login-item || warn "could not unregister the login item"
      rm -rf "$INSTALLED"
      say "removed $INSTALLED"
    else
      stop_all
      note "$INSTALLED is not installed"
    fi
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && note "removed preferences" || true
    ;;

  status)
    if pgrep -x "$NAME" >/dev/null; then
      say "running: $(pgrep -x "$NAME" | xargs ps -o pid=,command= -p | head -3)"
    else
      note "not running"
    fi
    if [ -e "$INSTALLED" ]; then
      say "installed: $INSTALLED (v$(defaults read "$INSTALLED/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?'))"
      note "login item: $("$INSTALLED/Contents/MacOS/$NAME" --login-item-status)"
    else
      note "not installed in $INSTALL_DIR"
    fi
    ;;

  icon)
    swift build >/dev/null
    .build/debug/$NAME --render-icon docs/icon.png --size 512
    ;;

  screenshot)
    swift build
    make_bundle debug "$DEV_APP"
    stop_all
    mkdir -p docs
    "$DEV_APP/Contents/MacOS/$NAME" --screenshot "$PWD/docs/screenshot.png" "$@"
    say "wrote docs/screenshot.png"
    ;;

  clean)
    rm -rf .build dist
    ;;

  *)
    sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
