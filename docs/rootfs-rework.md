# Rootfs rework

Adapted the bootstrap, Fedora image configuration, RPM templates, static monitor
configuration and image finalization of an earlier gaokun3 buildbot fork. See
upstream commits ca5d2010 and 0656fd81 for the RPM/environment and
firmware/boot-hook changes.

This record predates the pinned-kernel migration and is kept as history. The
kernel is now pinned by `build.env` (`KERNEL_COMMIT=73033564068250603f5b2150c408554faaf22d66`),
not by the commit named below.

At the time of this record both distributions kept an ESP and a single ext4 root
partition; the kernel was then pinned to 0a95cd00a3eb3a43f04746d2b4c6c9f1c7acf485,
whose bonded-DSI restoration resolved half-screen corruption in the user's test.
A Debian Btrfs image script was added later, so the ext4 statement now applies to
Ubuntu and Fedora only.

Fedora now uses GNOME initial setup to create the first account; there is no
user/user login. It retains explicit NetworkManager-tui installation, required
service enablement, SELinux configuration and offline labeling with -m for the
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
