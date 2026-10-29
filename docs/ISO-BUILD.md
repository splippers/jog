# JOG — ISO-based install (**Ubuntu 26.04 LTS**)

JOG is pinned to **Ubuntu Server 26.04** (`installer/UBUNTU_RELEASE`). Use the **live-server** amd64 image from [releases.ubuntu.com/26.04](https://releases.ubuntu.com/26.04/) (file name: `ubuntu-26.04-live-server-amd64.iso`).

| Goal | Use | After install |
|------|-----|---------------|
| **VM, one DVD, hands-off lab** | [Hyper-V one ISO](#hyper-v-gen2-one-iso-embedded-nocloud) | Unattended first-boot; optional **`jog-setup-reliable-kiosk.sh`** ([§ After reboot](#after-the-vm-reboots)) |
| **Full wizard (USB NIC, etc.)** | [Two ISOs + `autoinstall`](#vm-boot-wizard-end-to-end-two-isos-recommended) | **`jog-install-wizard`**, FOG, then **`jog-setup-reliable-kiosk.sh`** ([§ Graphical kiosk](#graphical-session-autologin-fog-management-tab-x11-latitude-class-laptops)) |

JOG ships two layers:

1. **Unattended base OS** — autoinstall (`installer/autoinstall/`) installs dnsmasq, git, clones JOG to `/opt/JOG`, and drops helper units.
2. **Interactive network + FOG** — after reboot, run **`sudo jog-install-wizard`** (dialog TUI). That runs **`jog-provision-stack.sh`** (signed EFI under **`/tftpboot/ubuntu-signed/`**, dnsmasq, native FOG in the background). `/etc/profile.d/jog-remind.sh` reflects **`wizard.done`** and **`fog-native.done`**.

Canonical reference (same major): [Autoinstall quick start](https://ubuntu.com/server/docs/install/autoinstall-quickstart) and Subiquity docs: [Providing autoinstall configuration](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html).

## VM boot: wizard end-to-end (**two ISOs**, recommended)

Use this when you want **`sudo jog-install-wizard`** after install (pick **`enx…`** USB NIC, IPs, DHCP, confirm onboard NIC if needed).

**1.** From the **`JOG` repo root on your build machine:

```bash
sudo apt update
sudo apt install -y cloud-image-utils xorriso openssl curl

./installer/fetch-ubuntu-live-server-iso.sh
( cd installer/autoinstall && ./render-user-data.sh 'YOUR-JOGADMIN-PASSWORD' )
./installer/build-cidata-seed-iso.sh
```

(`render-user-data.sh` without **`hyperv`** writes **`installer/autoinstall/user-data`** — the Hyper-V-only template is **`render-user-data.sh hyperv …`**.)

**2.** In Hyper-V Manager: **Generation 2** VM; attach:

| Virtual DVD | File |
|-------------|------|
| First DVD | **`installer/ubuntu-26.04-live-server-amd64.iso`** |
| Second DVD | **`installer/jog-autoinstall-seed.iso`** |

**3.** Boot the installer. At GRUB for the live ISO, append **`autoinstall`** to the **`linux`** line ([Ubuntu quick start](https://ubuntu.com/server/docs/install/autoinstall-quickstart)). Let Subiquity finish and reboot.

**4.** Log in as **`jogadmin`**, run **`sudo jog-install-wizard`**, watch **`journalctl -fu jog-fog-install.service`**. Then follow **Graphical session + autologin** (same page) so Chromium opens **`http://localhost/fog/management/`** after every reboot.

## Hyper-V Gen2 — one ISO (embedded nocloud)

Use this when you attach **exactly one** virtual DVD (no second CIDATA disc) to a **Generation 2** VM.

### Build the ISO (run on any machine with the JOG repo)

From the **`JOG` repo root**:

```bash
sudo apt update
sudo apt install -y xorriso openssl curl

./installer/fetch-ubuntu-live-server-iso.sh
./installer/build-hyperv-single-iso.sh 'YOUR-JOGADMIN-PASSWORD'
```

Outputs **`installer/ubuntu-26.04-live-server-jog-hyperv-amd64.iso`** (override with **`OUT_ISO=...`**). The builder **xorriso-clones** Canonical’s live-server ISO, patches **`/boot/grub/grub.cfg`** and **`/boot/grub/loopback.cfg`** so the installer gets **`autoinstall`** + **`ds=nocloud\;s=/cdrom/nocloud/`**, adds **`/nocloud/`** (rendered **`user-data.hyperv`**), and **`/installer-extra/`** first-boot helpers.

Attach that ISO as the VM’s DVD, boot once, let autoinstall finish.

**Hyper-V:** use a **Generation 2** VM with the ISO as the boot DVD (UEFI). If Windows reports **could not find a valid bootloader**, use an ISO built with **`build-hyperv-single-iso.sh`** from current `main`: older builds used **`xorriso -boot_image any keep`**, which broke the hybrid **GPT / El Torito** layout after patching GRUB — rebuild fixes it (`-boot_image any replay`).

**Subiquity exits 100 on `curtin system-install` / retrieving packages:** `exit status 100` from APT usually means **no outbound path to Ubuntu mirrors** (DHCP/NAT/DNS/firewall). The Hyper-V autoinstall omits **`packages:`** during Subiquity — dependencies are **`apt-get install`**’d on **first boot** (`jog-first-boot-unattended.sh`) **before** the imaging-only netplan replaces DHCP. Ensure the VM’s switch provides **internet** until that service finishes (e.g. Hyper-V **Default Switch** NAT), or install from a network where **archive.ubuntu.com** is reachable.

**Installer looks frozen at curtin extract** (`acquiring and extracting image from cp:///tmp/.../mount`): Subiquity often prints **one line** and then stays quiet while it copies **several gigabytes** from the virtual DVD — on Hyper-V this can take **30–45+ minutes** with **no progress text**. Before assuming a hang: wait, ensure **≥4 GiB RAM** (prefer **fixed** memory; disable **Dynamic Memory** during install), **≥2 vCPUs**, store the **VHDX on a local SSD**, and keep the **ISO on local disk** (not a slow SMB share). Disable **checkpoints** on the VM for the install if I/O is sluggish.

### After the VM reboots

A **systemd oneshot** applies **`10.99.0.1/24`**-style defaults on the **first Ethernet NIC**, runs **`jog-provision-stack.sh --blocking-fog`** (EFI → **`/tftpboot/ubuntu-signed`**, dnsmasq, **blocking** **`fog-native-install.sh`**), touches **`/etc/jog/wizard.done`** — no interactive **`jog-install-wizard`** on this path.

For a **graphical Chromium kiosk on the VM** (same **X11 / LightDM** stack as physical Latitudes), run **`sudo jog-setup-reliable-kiosk.sh jogadmin`** after login (large download). For production laptops you usually want the **two-ISO + wizard** flow so **`enx…`** USB imaging can be chosen explicitly.

**Limits:** suited to a **single-NIC VM** on an isolated/lab switch. Physical laptops with **USB imaging + WiFi** should keep the **two-ISO + wizard** workflow below.

## Why two steps?

Autoinstall cannot know your **USB NIC name**, **safe IP ranges** beside a corporate LAN, or your **hostname** on every laptop. The wizard collects those on the installed system.

## 1) Download the 26.04 live-server ISO

From the JOG repo:

```bash
./installer/fetch-ubuntu-live-server-iso.sh
```

This script is **hash-aware**:

- If the ISO already exists, it verifies it against Canonical’s published `SHA256SUMS` and **skips** downloading when it matches.
- If the checksum does not match, it deletes the file and re-downloads.

Writes `installer/ubuntu-26.04-live-server-amd64.iso` (override path: `./installer/fetch-ubuntu-live-server-iso.sh /path/to/out.iso`).

## 2) Build the CIDATA seed ISO

```bash
sudo apt update
sudo apt install -y cloud-image-utils xorriso openssl curl

# Render autoinstall config (choose a temporary install password)
( cd installer/autoinstall && ./render-user-data.sh 'TEMP-PASSWORD-HERE' )

# Build the CIDATA seed ISO
./installer/build-cidata-seed-iso.sh
```

Produces **`installer/jog-autoinstall-seed.iso`**. If `cloud-localds` is installed, the seed is built the same way as in the [Ubuntu autoinstall quick start](https://ubuntu.com/server/docs/install/autoinstall-quickstart#using-another-volume-to-provide-the-autoinstall-configuration); otherwise the script falls back to `xorriso`.

## Re-run “prep” end-to-end (both ISOs)

If you just want to regenerate both ISO files in one go:

```bash
cd /mnt/EDDIE-SANDIEGO/Projects/JOG
sudo apt update
sudo apt install -y cloud-image-utils xorriso openssl curl
./installer/fetch-ubuntu-live-server-iso.sh
( cd installer/autoinstall && ./render-user-data.sh 'TEMP-PASSWORD-HERE' )
./installer/build-cidata-seed-iso.sh
```

## 3) Boot the installer (VM or bare metal)

**Second-volume method** (matches Ubuntu quick start):

- **Drive 1**: `ubuntu-26.04-live-server-amd64.iso` (USB or virtual CD)
- **Drive 2**: `jog-autoinstall-seed.iso` (second USB or virtual CD)

At the bootloader, edit the kernel command line and add **`autoinstall`** so the installer consumes the autoinstall config **without** interactive disk confirmation (see quick start: *“add the autoinstall parameter to the kernel command line”*).

**Network method** (optional): serve `user-data` / `meta-data` over HTTP and boot with something like:

`autoinstall ds=nocloud-net\;s=http://<host>:<port>/`

(Exact URL encoding depends on your boot loader; see the [quick start network section](https://ubuntu.com/server/docs/install/autoinstall-quickstart#providing-the-autoinstall-data-over-the-network).)

## After first boot

1. Log in as **`jogadmin`** (password from `./render-user-data.sh`).
2. **`sudo jog-install-wizard`** — this also runs **`jog-provision-stack.sh`**: signed Ubuntu EFI → **`/tftpboot/ubuntu-signed`**, renders **dnsmasq**, restarts it, and **starts native FOG in the background** (`jog-fog-install.service`). Watch: **`journalctl -fu jog-fog-install.service`**.

If you only edited **`/etc/jog/jog.env`**: **`sudo jog-provision-stack.sh`**

### Graphical session + autologin + FOG management tab (X11 — Latitude-class laptops)

Server ISO installs have **no desktop** by default. For **reliable** Chromium on **Intel iGPU** machines (e.g. **Dell Latitude 3410**), use an **Xorg** desktop session (**`ubuntu-xorg`**) and LightDM — not the default Ubuntu **Wayland** session — so the stack matches **`chromium-jog.sh`** (**`--ozone-platform=x11`**).

After **`jog-install-wizard`** (so **`/etc/jog/jog.env`** exists):

```bash
sudo jog-setup-reliable-kiosk.sh jogadmin
sudo reboot
```

That installs **`ubuntu-desktop-minimal`**, **`ubuntu-session`** (provides **`ubuntu-xorg`**), **`lightdm`**, **`chromium-browser`**, firmware/Mesa helpers, writes **`lightdm/50-jog-autologin.conf.example`** as **`/etc/lightdm/lightdm.conf.d/50-jog-autologin.conf`** with **`user-session=ubuntu-xorg`** and **`autologin-session=ubuntu-xorg`**, and sets **`graphical.target`**.

(`jog-install-wizard` sets **`JOG_FOG_URL=http://localhost/fog/management/`**; **`kiosk/chromium-jog.sh`** uses **`GDK_BACKEND=x11`**, **`--ozone-platform=x11`**, and by default restarts Chromium if it exits.)

If **`dpkg`** still configured **gdm**, run **`sudo dpkg-reconfigure lightdm`** and choose **lightdm**.
