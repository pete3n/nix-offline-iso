    # --- proxied-iso: persist the Cache URL into the target ---
    # Injected by the nix-offline-iso graphical-proxy overlay, before
    # `cfg += cfgtail` closes the generated attrset. When the operator chose
    # a Proxied install, the Proxy screen wrote the Cache URL to
    # /run/nix-cache-url; point the target's nix at the Cache proxy so the
    # first nixos-rebuild works on the filtered network, and disable the
    # global flake registry (channels.nixos.org is unreachable there). No
    # file — a Direct install — means nothing is appended.
    _proxy_url_file = "/run/nix-cache-url"
    _proxy_url = None
    try:
        with open(_proxy_url_file, "r") as _proxy_fh:
            _proxy_url = _proxy_fh.read().strip()
    except OSError:
        _proxy_url = None
    if _proxy_url and not re.fullmatch(r"https?://[A-Za-z0-9.:/_-]+", _proxy_url):
        # The Proxy screen validates before writing, so a mismatch means the
        # file was written by something else. Refuse to interpolate it into a
        # Nix string rather than install a config that cannot evaluate.
        libcalamares.utils.warning(
            "ignoring malformed cache URL {!r} from {}".format(
                _proxy_url, _proxy_url_file
            )
        )
        _proxy_url = None
    if _proxy_url:
        cfg += (
            "  # Route Nix through the LAN cache proxy that performed this install.\n"
            "  # Written by the proxied installer; remove if this machine leaves\n"
            "  # the filtered network.\n"
            '  nix.settings.substituters = [ "' + _proxy_url + '" ];\n'
            "  # The global flake registry lives on channels.nixos.org, which the\n"
            "  # cache proxy does not expose; disable the fetch instead of letting\n"
            "  # flake commands hang on it.\n"
            '  nix.settings.flake-registry = "";\n'
            "\n"
        )
    # --- end proxied-iso persist ---
