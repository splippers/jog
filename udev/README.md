# udev rules: examples only

These two rules are what the Latitude test rig uses. They hard-code that machine's USB Ethernet MAC and its
faulty USB hub IDs, so they are **examples**. On any other laptop run `sudo jog-hardware-wizard`, which detects
the imaging adapter and any faulty hubs and writes the real `/etc/udev/rules.d/99-jog-*.rules` for that machine.
