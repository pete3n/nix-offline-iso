#!/usr/bin/env python3
"""The Proxy screen:
  proxy-screen              GTK window. Exits 0 when the operator presses
                            Continue (the launcher then execs Calamares),
                            1 when they close or quit instead.
  proxy-screen --apply URL  Root-only helper the window invokes via
                            `sudo -n` for a Proxied install: reroutes the
                            live environment's substituters to URL and
                            records URL for the nixos job module's
                            proxy-persist injection.

The Reachability probe fetches `<url>/nix-cache-info` and expects a Nix
binary-cache answer (a body starting with `StoreDir:`). Continue stays
disabled until the probe matching the currently selected mode (and URL)
has passed.
"""

import os
import re
import subprocess
import sys
import threading
import urllib.error
import urllib.request

# Substituted at build time by the overlay in flake.nix. The env var is an
# operator override for running the screen outside the ISO.
DEFAULT_CACHE_URL = os.environ.get("PROXY_SCREEN_DEFAULT_URL", "@cacheUrlDefault@")

# A Direct install probes the real cache: the same "my package source
# answers" guarantee, with nothing rerouted.
DIRECT_PROBE_URL = "https://cache.nixos.org"

# Must stay in sync with the proxy-persist injection's pattern: only
# characters that can neither break out of a Nix string nor smuggle
# nix.conf syntax.
CACHE_URL_RE = re.compile(r"^https?://[A-Za-z0-9.:/_-]+$")

NIX_CONF_PATH = "/etc/nix/nix.conf"
CACHE_URL_FILE = "/run/nix-cache-url"
PROBE_TIMEOUT_SECONDS = 5


def probe(base_url, timeout_seconds=PROBE_TIMEOUT_SECONDS):
    """Return (ok, message) for whether base_url answers like a Nix cache."""
    probe_url = base_url.rstrip("/") + "/nix-cache-info"
    try:
        with urllib.request.urlopen(probe_url, timeout=timeout_seconds) as response:
            body = response.read(512)
    except urllib.error.HTTPError as error:
        return False, "HTTP {} from {}".format(error.code, probe_url)
    except (urllib.error.URLError, OSError, ValueError) as error:
        reason = getattr(error, "reason", None) or error
        return False, "Unreachable: {}".format(reason)
    if not body.startswith(b"StoreDir:"):
        return False, "{} answered, but not like a Nix binary cache".format(probe_url)
    return True, "Nix binary cache answered"


def rewrite_nix_conf(cache_url, conf_path=NIX_CONF_PATH):
    """Point the live environment's substituters at the Cache proxy.

    /etc/nix/nix.conf on the live ISO is a symlink into the read-only store,
    so replace it with a regular file: the same content minus any existing
    substituters line.
    """
    with open(conf_path, "r") as conf_file:
        original_lines = conf_file.read().splitlines()
    kept = [
        line
        for line in original_lines
        if line.split("=", 1)[0].strip() != "substituters"
    ]
    kept += [
        "",
        "# Rerouted to the Cache proxy by the proxied installer (Proxy screen).",
        "substituters = " + cache_url,
    ]
    replacement_path = conf_path + ".proxy-screen"
    with open(replacement_path, "w") as replacement_file:
        replacement_file.write("\n".join(kept) + "\n")
    if os.path.islink(conf_path):
        os.unlink(conf_path)
    os.replace(replacement_path, conf_path)


def apply_proxied(
    cache_url,
    conf_path=NIX_CONF_PATH,
    url_file=CACHE_URL_FILE,
    restart_daemon=True,
):
    """Root half of a Proxied install: reroute live nix, then record the URL.

    Ordering matters: the URL file is written last, so a failed daemon
    restart leaves no record and the nixos job persists nothing, and the
    system never ends up half-configured.
    """
    if not CACHE_URL_RE.match(cache_url):
        raise ValueError("malformed cache URL: {!r}".format(cache_url))
    rewrite_nix_conf(cache_url, conf_path)
    if restart_daemon:
        subprocess.run(["systemctl", "restart", "nix-daemon.service"], check=True)
    with open(url_file, "w") as url_fh:
        url_fh.write(cache_url + "\n")


def run_ui():
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk

    exit_code = {"value": 1}  # closed/quit without Continue
    # passed = (mode, url) of the last successful probe; None invalidates.
    state = {"passed": None, "probing": False}

    window = Gtk.Window(title="NixOS Installer — Network Access")
    window.set_border_width(18)
    window.set_position(Gtk.WindowPosition.CENTER)
    window.set_resizable(False)

    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    window.add(box)

    heading = Gtk.Label()
    heading.set_markup("<b>How should this install reach its packages?</b>")
    heading.set_xalign(0)
    box.pack_start(heading, False, False, 0)

    proxied_radio = Gtk.RadioButton.new_with_label_from_widget(
        None, "Through the LAN cache proxy (Proxied install)"
    )
    direct_radio = Gtk.RadioButton.new_with_label_from_widget(
        proxied_radio, "Directly from the internet (Direct install)"
    )
    box.pack_start(proxied_radio, False, False, 0)

    url_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    url_label = Gtk.Label(label="Cache URL:")
    url_entry = Gtk.Entry()
    url_entry.set_text(DEFAULT_CACHE_URL)
    url_entry.set_width_chars(38)
    url_row.pack_start(url_label, False, False, 12)
    url_row.pack_start(url_entry, True, True, 0)
    box.pack_start(url_row, False, False, 0)
    box.pack_start(direct_radio, False, False, 0)

    status_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    spinner = Gtk.Spinner()
    status_label = Gtk.Label(label="Testing the connection…")
    status_label.set_xalign(0)
    status_label.set_line_wrap(True)
    status_row.pack_start(spinner, False, False, 0)
    status_row.pack_start(status_label, True, True, 0)
    box.pack_start(status_row, False, False, 0)

    button_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    test_button = Gtk.Button(label="Test connection")
    quit_button = Gtk.Button(label="Quit")
    continue_button = Gtk.Button(label="Continue")
    continue_button.set_sensitive(False)
    button_row.pack_start(test_button, False, False, 0)
    button_row.pack_end(continue_button, False, False, 0)
    button_row.pack_end(quit_button, False, False, 0)
    box.pack_start(button_row, False, False, 6)

    def selection():
        if proxied_radio.get_active():
            return "proxied", url_entry.get_text().strip().rstrip("/")
        return "direct", DIRECT_PROBE_URL

    def invalidate(*_args):
        state["passed"] = None
        continue_button.set_sensitive(False)
        url_entry.set_sensitive(proxied_radio.get_active())

    def probe_finished(probed, ok, message):
        state["probing"] = False
        spinner.stop()
        test_button.set_sensitive(True)
        if ok and probed == selection():
            state["passed"] = probed
            continue_button.set_sensitive(True)
            status_label.set_text("✔ " + message)
        elif ok:
            status_label.set_text("Settings changed during the test — test again.")
        else:
            status_label.set_text("✘ " + message)
        return False  # one-shot idle callback

    def on_test(_widget):
        if state["probing"]:
            return
        mode, url = selection()
        if mode == "proxied" and not CACHE_URL_RE.match(url):
            status_label.set_text(
                "✘ Not a usable URL: plain http(s)://host[:port][/path], "
                "no spaces or quotes."
            )
            return
        state["probing"] = True
        state["passed"] = None
        continue_button.set_sensitive(False)
        test_button.set_sensitive(False)
        spinner.start()
        status_label.set_text("Probing {} …".format(url))

        def worker():
            ok, message = probe(url)
            GLib.idle_add(probe_finished, (mode, url), ok, message)

        threading.Thread(target=worker, daemon=True).start()

    def on_continue(_button):
        if state["passed"] is None or state["passed"] != selection():
            invalidate()
            status_label.set_text("Test the connection first.")
            return
        mode, url = state["passed"]
        if mode == "proxied":
            # Re-run this same script as root for the system mutations. The
            # live user's wheel sudo is passwordless on installer images.
            apply_cmd = ["sudo", "-n", os.path.abspath(sys.argv[0]), "--apply", url]
            result = subprocess.run(apply_cmd, capture_output=True, text=True)
            if result.returncode != 0:
                details = (result.stderr or result.stdout or "").strip().splitlines()
                status_label.set_text(
                    "✘ Rerouting the live environment failed: "
                    + (details[-1] if details else "unknown error")
                )
                return
        exit_code["value"] = 0
        window.close()

    proxied_radio.connect("toggled", invalidate)
    url_entry.connect("changed", invalidate)
    url_entry.connect("activate", on_test)
    test_button.connect("clicked", on_test)
    continue_button.connect("clicked", on_continue)
    quit_button.connect("clicked", lambda _button: window.close())
    window.connect("destroy", Gtk.main_quit)

    window.show_all()
    invalidate()
    # Auto-probe the prefilled default so the common case is a single
    # Continue click.
    GLib.idle_add(on_test, None)
    Gtk.main()
    return exit_code["value"]


def main(argv):
    if len(argv) >= 2 and argv[1] == "--apply":
        if len(argv) != 3:
            print("usage: proxy-screen --apply <cache-url>", file=sys.stderr)
            return 2
        if os.geteuid() != 0:
            print("proxy-screen --apply must run as root", file=sys.stderr)
            return 2
        try:
            apply_proxied(argv[2])
        except Exception as error:  # surfaced verbatim in the status label
            print("proxy-screen --apply: {}".format(error), file=sys.stderr)
            return 1
        return 0
    return run_ui()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
