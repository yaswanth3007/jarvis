#!/usr/bin/env python3
"""Jarvis Voice for Linux: read and operate app windows through AT-SPI.

AT-SPI is the desktop's accessibility API (what the Orca screen reader uses). It works on
X11 and Wayland alike, for GTK, Qt, Firefox, Chromium/Electron and LibreOffice apps that
expose accessibility. Called by client/adapters/linux.mjs, one command per run, answering
one JSON object on stdout. It never reads password fields.

  linux-atspi.py apps
  linux-atspi.py read  <app>
  linux-atspi.py click <app> <label> [role]
  linux-atspi.py type  <app> <text> [field] [submit:0|1]
"""
import json
import re
import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

MAX_NODES = 3000
MAX_CHARS = 12000
PRESSABLE = {"push button", "toggle button", "check box", "radio button", "link", "menu item", "check menu item",
             "radio menu item", "page tab", "list item", "tree item", "table cell", "combo box", "toggle", "button"}
EDITABLE = {"text", "entry", "password text", "terminal", "document text", "paragraph", "editbar", "spin button"}


def norm(s):
    return re.sub(r"[^\w]+", " ", (s or "").lower()).strip()


def out(obj, code=0):
    sys.stdout.write(json.dumps(obj))
    sys.stdout.flush()
    sys.exit(code)


def apps():
    desktop = Atspi.get_desktop(0)
    found = []
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is None:
            continue
        try:
            found.append((app, app.get_name() or ""))
        except Exception:
            continue
    return found


def find_app(name):
    want = norm(name)
    candidates = apps()
    for exact in (True, False):
        for app, app_name in candidates:
            n = norm(app_name)
            if not n:
                continue
            if (exact and n == want) or (not exact and (want in n or n in want)):
                return app
    # The window title often carries the app's name when the accessible app name does not.
    for app, _ in candidates:
        try:
            for j in range(app.get_child_count()):
                win = app.get_child_at_index(j)
                if win is not None and want and want in norm(win.get_name()):
                    return app
        except Exception:
            continue
    return None


def role(acc):
    try:
        return acc.get_role_name() or ""
    except Exception:
        return ""


def states(acc):
    try:
        return acc.get_state_set()
    except Exception:
        return None


def has(acc, state):
    s = states(acc)
    return bool(s and s.contains(state))


def text_of(acc):
    try:
        t = acc.get_text_iface() if hasattr(acc, "get_text_iface") else acc.get_text()
        if t is None:
            return ""
        n = Atspi.Text.get_character_count(acc)
        return Atspi.Text.get_text(acc, 0, min(n, 6000)) if n > 0 else ""
    except Exception:
        return ""


def walk(root):
    stack = [(root, 0)]
    count = 0
    while stack and count < MAX_NODES:
        acc, depth = stack.pop()
        count += 1
        yield acc, depth
        if depth > 24:
            continue
        try:
            n = acc.get_child_count()
        except Exception:
            continue
        kids = []
        for i in range(min(n, 400)):
            try:
                c = acc.get_child_at_index(i)
            except Exception:
                c = None
            if c is not None:
                kids.append(c)
        for c in reversed(kids):
            stack.append((c, depth + 1))


def active_window(app):
    try:
        for j in range(app.get_child_count()):
            win = app.get_child_at_index(j)
            if win is not None and has(win, Atspi.StateType.ACTIVE):
                return win
        return app.get_child_at_index(0) if app.get_child_count() else app
    except Exception:
        return app


def read(name):
    app = find_app(name)
    if app is None:
        out({"error": f"{name} is not open, or it does not expose accessibility (AT-SPI)."}, 2)
    win = active_window(app)
    lines, seen, size = [], set(), 0
    for acc, depth in walk(win):
        r = role(acc)
        if r == "password text":
            label = (acc.get_name() or "").strip()
            line = f"[{r}] {label} (password field)"
        else:
            label = ""
            try:
                label = (acc.get_name() or "").strip()
            except Exception:
                pass
            body = text_of(acc).strip() if r in EDITABLE or r in {"label", "heading", "static", "document web", "document frame"} else ""
            content = label if not body or body == label else (f"{label}: {body}" if label else body)
            if not content:
                continue
            line = "  " * min(depth, 8) + f"[{r}] " + re.sub(r"\s+", " ", content)
        key = line.strip()
        if key in seen:
            continue
        seen.add(key)
        lines.append(line)
        size += len(line)
        if size > MAX_CHARS:
            lines.append("…")
            break
    try:
        title = win.get_name() or ""
    except Exception:
        title = ""
    out({"title": title, "text": "\n".join(lines)})


def find_element(root, label, want_role=None, editable=False):
    want = norm(label)
    best, best_score = None, 0
    for acc, _ in walk(root):
        r = role(acc)
        if editable and r not in EDITABLE:
            continue
        try:
            n = norm(acc.get_name())
        except Exception:
            n = ""
        if not n or not want:
            continue
        score = 3 if n == want else 2 if n.startswith(want) else 1 if want in n else 0
        if not score:
            continue
        if want_role and norm(want_role) in norm(r):
            score += 2
        if r in PRESSABLE:
            score += 1
        if not has(acc, Atspi.StateType.SHOWING):
            score -= 1
        if score > best_score:
            best, best_score = acc, score
    return best


def click(name, label, want_role=None):
    app = find_app(name)
    if app is None:
        out({"error": f"{name} is not open, or it does not expose accessibility (AT-SPI)."}, 2)
    acc = find_element(active_window(app), label, want_role)
    if acc is None:
        out({"error": f"There is nothing labelled '{label}' in {name}."}, 2)
    try:
        n = Atspi.Action.get_n_actions(acc)
        names = [Atspi.Action.get_action_name(acc, i) for i in range(n)]
        for preferred in ("click", "press", "activate", "jump", "toggle", "select", "open"):
            if preferred in names:
                Atspi.Action.do_action(acc, names.index(preferred))
                out({"result": f"pressed '{acc.get_name()}'"})
        if n > 0:
            Atspi.Action.do_action(acc, 0)
            out({"result": f"pressed '{acc.get_name()}'"})
    except Exception as err:  # noqa: BLE001
        out({"error": f"'{label}' could not be pressed: {err}"}, 2)
    out({"error": f"'{label}' can't be pressed through accessibility."}, 2)


def type_text(name, text, field=None, submit=False):
    app = find_app(name)
    if app is None:
        out({"error": f"{name} is not open, or it does not expose accessibility (AT-SPI)."}, 2)
    win = active_window(app)
    target = find_element(win, field, editable=True) if field else None
    if target is None:
        for acc, _ in walk(win):
            if role(acc) in EDITABLE and has(acc, Atspi.StateType.FOCUSED):
                target = acc
                break
    if target is None:
        out({"error": "No text field to type into was found (none is focused)." if not field else f"There is no field called '{field}'."}, 2)
    if role(target) == "password text":
        out({"error": "That is a password field; Jarvis never types into password fields."}, 2)
    if not has(target, Atspi.StateType.EDITABLE):
        out({"error": "That field can't be edited."}, 2)
    try:
        caret = Atspi.Text.get_caret_offset(target)
        if caret < 0:
            caret = Atspi.Text.get_character_count(target)
        Atspi.EditableText.insert_text(target, caret, text, len(text.encode("utf-8")))
    except Exception as err:  # noqa: BLE001
        out({"error": f"Typing failed: {err}", "fallback": True}, 3)
    verified = text in text_of(target)
    submitted = False
    if submit:
        try:
            Atspi.Component.grab_focus(target)
            submitted = Atspi.generate_keyboard_event(0xFF0D, None, Atspi.KeySynthType.SYM)  # Return
        except Exception:
            submitted = False
    out({"result": "typed", "verified": verified, "submitted": submitted})


def main(argv):
    if len(argv) < 2:
        out({"error": "usage"}, 64)
    cmd = argv[1]
    if cmd == "apps":
        out({"apps": [n for _, n in apps() if n]})
    if cmd == "read" and len(argv) >= 3:
        read(argv[2])
    if cmd == "click" and len(argv) >= 4:
        click(argv[2], argv[3], argv[4] if len(argv) > 4 and argv[4] else None)
    if cmd == "type" and len(argv) >= 4:
        type_text(argv[2], argv[3], argv[4] if len(argv) > 4 and argv[4] else None, len(argv) > 5 and argv[5] == "1")
    out({"error": f"unknown command {cmd}"}, 64)


if __name__ == "__main__":
    main(sys.argv)
