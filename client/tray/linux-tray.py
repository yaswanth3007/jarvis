#!/usr/bin/env python3
"""Jarvis Voice's status icon on Linux (StatusNotifierItem through AppIndicator).

Started by client/tray.mjs. Reads {"status","muted","tip","notify"} lines on stdin; writes
"menu <id>" lines when the user picks a menu item. GNOME shows it with the AppIndicator
extension (Ubuntu ships it); KDE, Xfce, Cinnamon and most others show it natively.
"""
import json
import sys

import gi

gi.require_version("Gtk", "3.0")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402

ICON, MUTED_ICON = "audio-input-microphone", "microphone-sensitivity-muted"


def say(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


ind = AppIndicator.Indicator.new("jarvis-voice", ICON, AppIndicator.IndicatorCategory.APPLICATION_STATUS)
ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
ind.set_title("Jarvis Voice")
menu = Gtk.Menu()
status = Gtk.MenuItem(label="Starting…")
status.set_sensitive(False)
menu.append(status)
menu.append(Gtk.SeparatorMenuItem())
mute = Gtk.MenuItem(label="Pause listening")
mute.connect("activate", lambda *_: say("menu mute"))
menu.append(mute)
for label, ident in (("Open the JARVIS interface", "face"), ("Open the logs folder", "logs")):
    item = Gtk.MenuItem(label=label)
    item.connect("activate", lambda _w, i=ident: say(f"menu {i}"))
    menu.append(item)
menu.append(Gtk.SeparatorMenuItem())
quit_item = Gtk.MenuItem(label="Quit Jarvis Voice")
quit_item.connect("activate", lambda *_: say("menu quit"))
menu.append(quit_item)
menu.show_all()
ind.set_menu(menu)


def on_input(source, _cond):
    line = source.readline()
    if not line:
        Gtk.main_quit()
        return False
    try:
        m = json.loads(line)
    except ValueError:
        return True
    if m.get("status"):
        status.set_label(str(m["status"]))
    if m.get("muted") is not None:
        mute.set_label("Resume listening" if m["muted"] else "Pause listening")
        ind.set_icon_full(MUTED_ICON if m["muted"] else ICON, "Jarvis Voice")
    return True


GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, on_input)
say("ready")
Gtk.main()
