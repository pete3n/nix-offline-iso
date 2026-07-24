    # --- offline-iso: copy user-provided configuration into the target ---
    # Injected by the nix-offline-iso overlay (NOT upstream). This runs after
    # configuration.nix + hardware-configuration.nix have been generated, but
    # before nixos-install is invoked, so the user's own files are what actually
    # gets installed. A local `import tempfile` keeps this block self-contained,
    # so the overlay only needs a single, stable injection anchor.
    import tempfile

    _offline_dynamic_cfg = "/tmp/nix-cfg"
    _offline_iso_cfg = "/iso/nix-cfg"

    def _offline_has_cfg(cfg_dir):
        # A usable config dir has either a plain configuration.nix (channels)
        # or a flake.nix (flake install).
        return os.path.exists(os.path.join(cfg_dir, "configuration.nix")) or \
            os.path.exists(os.path.join(cfg_dir, "flake.nix"))

    # /tmp/nix-cfg (dynamically edited after boot) takes precedence over the
    # baked-in /iso/nix-cfg, matching the documented behavior.
    if _offline_has_cfg(_offline_dynamic_cfg):
        _offline_src = _offline_dynamic_cfg
    elif _offline_has_cfg(_offline_iso_cfg):
        _offline_src = _offline_iso_cfg
    else:
        _offline_src = None

    # Always define this: the nixos-install command below references it
    # unconditionally (see the injected --flake spread).
    offline_flake_ref = None
    _offline_hw_dest = os.path.join(
        root_mount_point, "etc/nixos/hardware-configuration.nix"
    )
    _offline_tmp = ""
    if _offline_src is not None:
        try:
            # Preserve the freshly generated hardware-configuration.nix; the user
            # copy may carry a template that would otherwise clobber it.
            with open(_offline_hw_dest, "r") as _offline_hw_file:
                _offline_hw = _offline_hw_file.read()
            for _offline_entry in os.listdir(_offline_src):
                _offline_from = os.path.join(_offline_src, _offline_entry)
                _offline_to = os.path.join(
                    root_mount_point, "etc/nixos", _offline_entry
                )
                # Use the same host-env helper the module already uses to write
                # configuration.nix (runs as root, non-interactive) rather than
                # sudo/pkexec, which may not work unattended here.
                if os.path.isdir(_offline_from):
                    libcalamares.utils.host_env_process_output(
                        ["cp", "-rT", _offline_from, _offline_to], None
                    )
                else:
                    libcalamares.utils.host_env_process_output(
                        ["cp", "-f", _offline_from, _offline_to], None
                    )
            # Restore the generated hardware-configuration.nix so the install
            # matches the real target hardware.
            with tempfile.NamedTemporaryFile(mode="w", delete=False) as _offline_tf:
                _offline_tf.write(_offline_hw)
                _offline_tmp = _offline_tf.name
            libcalamares.utils.host_env_process_output(
                ["cp", "-f", _offline_tmp, _offline_hw_dest], None
            )
        except Exception as _offline_err:
            return (
                "Installation failed to copy configuration files",
                str(_offline_err),
            )
        finally:
            # _offline_tmp is set before use, so this never NameErrors even if
            # the very first open() above throws.
            if _offline_tmp and os.path.exists(_offline_tmp):
                os.remove(_offline_tmp)

        # If the copied config is a flake, switch nixos-install to flake mode.
        # The hostname the user entered in Calamares must match a
        # nixosConfigurations.<name> attribute in their flake.
        if os.path.exists(os.path.join(root_mount_point, "etc/nixos/flake.nix")):
            _offline_host = gs.value("hostname") or "nixos"
            offline_flake_ref = (
                os.path.join(root_mount_point, "etc/nixos") + "#" + _offline_host
            )
    # --- end offline-iso config copy ---
