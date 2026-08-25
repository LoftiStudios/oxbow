# dmgbuild settings for the Oxbow release disk image.
#
# The icon coordinates here MUST match the ones printed by
# scripts/dmg/make-background.swift — the background artwork paints an arrow
# between two positions and Finder puts the real icons on top of it. If these
# drift, the arrow points at nothing.
#
# Driven by scripts/package-dmg.sh; not meant to be run by hand.

import os.path

app = defines["app"]                    # the signed, stapled Oxbow.app
licenses = defines["licenses"]          # the staged Licenses/ folder
resources = defines["resources"]        # scripts/dmg
background_name = defines.get("background", "background.tiff")

appname = os.path.basename(app)

# ---------------------------------------------------------------- image

format = "ULFO"                         # lzfse; fine on 10.11+, we target 15
filesystem = "HFS+"                     # APFS images do not mount before 10.13

files = [app, licenses]
symlinks = {"Applications": "/Applications"}

# The volume icon. package-dmg.sh pulls this out of the app bundle itself, so
# there is no second copy of the icon to keep in sync.
icon = os.path.join(resources, "VolumeIcon.icns")

# ---------------------------------------------------------------- window

background = os.path.join(resources, background_name)

window_rect = ((200, 180), (640, 400))  # size MUST equal the @1x artwork size
default_view = "icon-view"

show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# ---------------------------------------------------------------- icons

icon_size = 96
text_size = 12                          # Finder's own default; dmgbuild's is 16
label_pos = "bottom"
arrange_by = None

icon_locations = {
    appname:        (172, 196),
    "Applications": (468, 196),
    "Licenses":     (320, 296),
}
