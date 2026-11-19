# dmgbuild settings for put's disk image (input/release.yml; tools/dmg-requirements.txt pins
# dmgbuild). The window opens on put, a link to Applications and the background drawn for it
# (Resources/dmg/background.svg). Defines: app (put.app), background (background.png; its @2x
# beside it is found and joined into one HiDPI image), icon (the volume's icon: put's own).
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
# The background is 640 x 430: whether Finder counts the title bar in these bounds or not, what
# matters is above its last 30 points.
window_rect = ((200, 140), (640, 430))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
# Where the background leaves room for them (centres, in points from the top left).
icon_locations = {"put.app": (170, 200), "Applications": (470, 200)}
