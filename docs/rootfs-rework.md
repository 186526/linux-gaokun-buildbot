# Rootfs rework

Reference: PeronGH/linux-gaokun-buildbot at a7aac4ae6a04f42fe4adf46cea60cfa4258b1bbf.
Adapted its bootstrap, Fedora image configuration, RPM templates, static monitor
configuration and image finalization. See upstream commits ca5d2010 and 0656fd81
for the RPM/environment and firmware/boot-hook changes.

Both distributions keep an ESP and a single ext4 root partition. The kernel
remains pinned to 0a95cd00a3eb3a43f04746d2b4c6c9f1c7acf485, whose bonded-DSI
restoration resolved half-screen corruption in the user's test.

Fedora now uses GNOME initial setup to create the first account; there is no
user/user login. It retains explicit NetworkManager-tui installation, required
service enablement, SELinux selection and offline labeling with -m for the
Ubuntu build host. The desktop uses system-wide monitors.xml (60 Hz, 200% scale)
without a service that restarts GDM. Plymouth is disabled and the boot menu
editor is enabled, matching Peron's debugging-friendly setup.

Firmware RPMs supplement Fedora's qcom/atheros packages with model-specific
files only. RPMs must be rebuilt for this candidate; older artifacts with the
same kernel SHA still carry the superseded firmware and install hooks.

The workflow preserves exact kernel SHA checks and opt-in publishing. Successful
assembly checks boot payloads, GDM components, service enablement and RPM
provides, but cannot prove GDM, networking or suspend works on hardware.

Ubuntu keeps its existing account/bootstrap configuration; shared static display
configuration and per-device identity cleanup are applied there as well.
Historical manual build guides describe the pre-migration workflow.
