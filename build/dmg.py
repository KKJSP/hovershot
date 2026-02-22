# build_dmg.py
import os

# The name of the DMG file to create
filename = "HoverShot.dmg"
# The volume name (what shows up on the desktop when mounted)
volume_name = "HoverShot v0.1.0"
# The path to your compiled .app
files = ["HoverShot.app"]

# Create a symlink to the Applications folder inside the DMG
symlinks = {"Applications": "/Applications"}

# Window configuration
window_rect = ((200, 120), (500, 400))
icon_size = 128

# Icon positions (x, y)
icon_locations = {
    "HoverShot.app": (140, 120),
    "Applications": (360, 120)
}

# Optional: Path to a background image (PNG)
# background = "installer_background.png"
