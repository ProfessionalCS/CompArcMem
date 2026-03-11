#!/bin/bash
export QUARTUS_ROOTDIR=/home/quartus/altera/25.1std
export PATH=$QUARTUS_ROOTDIR/quartus/bin:$PATH
export LD_LIBRARY_PATH=$QUARTUS_ROOTDIR/quartus/linux64:$LD_LIBRARY_PATH

# Force the X11 backend instead of Wayland for the Qt app
export QT_QPA_PLATFORM=xcb
export GDK_BACKEND=x11

# Disable Shared Memory (The #1 fix for Fedora/Docker crashes)
export QT_X11_NO_MITSHM=1

# Force software OpenGL (llvmpipe)
export QT_OPENGL=software
export LIBGL_ALWAYS_SOFTWARE=1
# export QT_XCB_GL_INTEGRATION=none
export MESA_GL_VERSION_OVERRIDE=3.3   # Optional: override Mesa GL version
# AMD's Mesa driver sometimes has DRI3 issues in containers
export LIBGL_DRI3_DISABLE=1
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
# Avoid indirect rendering unless really needed
unset LIBGL_ALWAYS_INDIRECT

# Java 2D rendering fix (optional, for Quartus GUI)
# export _JAVA_OPTIONS="-Dsun.java2d.opengl=false -Dsun.java2d.d3d=false -Dsun.java2d.xrender=false -Dsun.java2d.pmoffscreen=false -Dswing.aatext=false -Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel -Dsun.java2d.noddraw=true -Dsun.java2d.uiScale=1.5 -Dsun.java2d.uiScale.enabled=true"
# export JAVA_TOOL_OPTIONS="-Dsun.java2d.uiScale=1.5"
# export J2D_UISCALE=1.5
# export GDK_SCALE=1
# export GDK_DPI_SCALE=1

# Kill any existing (potentially hung) daemons
killall -9 jtagd 2>/dev/null

# Start the daemon
jtagd &
sleep 2

# Now check the hardware
jtagconfig

# OpenGL check
if command -v glxinfo >/dev/null 2>&1; then
    echo "OpenGL Renderer:"
    glxinfo | grep "OpenGL renderer string"
fi

# Launch Quartus
# quartus &

# Keep the terminal alive
exec /bin/bash
