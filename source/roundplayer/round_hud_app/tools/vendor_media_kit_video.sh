#!/bin/bash
# Vendors media_kit_video from the pub cache into round_hud_app/packages/ and applies the Raspberry Pi
# fixes. pubspec.yaml has a dependency_overrides entry pointing at packages/media_kit_video, so run this
# once before `flutter build linux` (install_pi.sh and deploy.sh do it for you). Idempotent.
#
# Fix: libmpv's OpenGL render backend (mpv <= 0.40) calls glFenceSync() for every rendered frame in
# ra_gl_ctx_submit_frame() and never deletes the fences (the libmpv_gl backend never calls
# ra_gl_ctx_swap_buffers). On Mesa/v3d a GL fence is a DRM sync_file fd, so the HUD leaked one fd per
# video frame, hit RLIMIT_NOFILE after a few minutes, and the screen went black / touch "hung".
# mpv only loads glFenceSync when GL_VERSION reports ES >= 3.0 (or GL_ARB_sync), so the vendored plugin
# hands mpv a glGetString that reports "OpenGL ES 2.0". MEDIA_KIT_NO_GLES2_SHIM=1 disables it at runtime.
set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="$(grep -A8 '^  media_kit_video:' "$APP_DIR/pubspec.lock" 2>/dev/null | grep -o 'version: "[^"]*"' | head -1 | cut -d'"' -f2 || true)"
VER="${VER:-2.0.1}"
PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
SRC="$PUB_CACHE/hosted/pub.dev/media_kit_video-$VER"
DST="$APP_DIR/packages/media_kit_video"

if [ ! -d "$SRC" ]; then
  echo "[vendor] media_kit_video-$VER not in pub cache, fetching"
  (cd "$APP_DIR" && dart pub cache add media_kit_video --version "$VER") || \
  (cd "$APP_DIR" && flutter pub cache add media_kit_video --version "$VER")
fi
[ -d "$SRC" ] || { echo "[vendor] cannot find $SRC"; exit 1; }

if [ -f "$DST/linux/video_output.cc" ] && grep -q media_kit_shim_glGetString "$DST/linux/video_output.cc"; then
  echo "[vendor] packages/media_kit_video already patched ($VER)"
  exit 0
fi

rm -rf "$DST"; mkdir -p "$APP_DIR/packages"
cp -r "$SRC" "$DST"
python3 - "$DST/linux/video_output.cc" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''              mpv_opengl_init_params gl_init_params{
                  [](auto, auto name) {
                    return (void*)eglGetProcAddress(name);
                  },
                  NULL,
              };'''
new = '''              mpv_opengl_init_params gl_init_params{
                  media_kit_get_proc_address,
                  NULL,
              };'''
assert old in s, "get_proc_address block not found - media_kit_video layout changed"
s = s.replace(old, new, 1)
inc = '#include <gdk/gdkx.h>\n'
shim = '''#include <gdk/gdkx.h>

#include <cstring>
#include <cstdlib>

// --- Fence-leak workaround (see tools/vendor_media_kit_video.sh) ----------------------------
// libmpv's OpenGL render backend (mpv <= 0.40) creates a vsync fence with glFenceSync() for every
// rendered frame in ra_gl_ctx_submit_frame() and never deletes them, because the libmpv_gl backend
// never calls ra_gl_ctx_swap_buffers(). On Mesa/v3d (Raspberry Pi) each GL fence is backed by a DRM
// sync_file fd, so the host process leaks one fd per video frame until it hits RLIMIT_NOFILE.
// mpv only loads glFenceSync when the context reports GLES >= 3.0 (or GL_ARB_sync), so we report
// the context as "OpenGL ES 2.0" to mpv. The real context is still ES 3.x (a superset), mpv just
// uses its GLES 2 code path. Set MEDIA_KIT_NO_GLES2_SHIM=1 to disable.
typedef const GLubyte* (*glGetString_t)(GLenum);
static glGetString_t media_kit_real_glGetString = NULL;

static const GLubyte* media_kit_shim_glGetString(GLenum name) {
  if (name == GL_VERSION) {
    return (const GLubyte*)"OpenGL ES 2.0 (media_kit fence-leak workaround)";
  }
  return media_kit_real_glGetString(name);
}

static void* media_kit_get_proc_address(void*, const char* name) {
  void* fn = (void*)eglGetProcAddress(name);
  static const bool shim_enabled = getenv("MEDIA_KIT_NO_GLES2_SHIM") == NULL;
  if (shim_enabled && fn != NULL && strcmp(name, "glGetString") == 0) {
    media_kit_real_glGetString = (glGetString_t)fn;
    return (void*)media_kit_shim_glGetString;
  }
  return fn;
}
'''
assert inc in s
s = s.replace(inc, shim, 1)
open(p, 'w').write(s)
print("[vendor] patched", p)
EOF
echo "[vendor] media_kit_video $VER vendored into packages/ with the fence-leak fix"
