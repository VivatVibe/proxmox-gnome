#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_FILE="${SCRIPT_DIR}/proxmox-gnome-laptop-9.2-amd64.hybrid.iso"
OUT_DIR="${1:-${SCRIPT_DIR}}"
mkdir -p "$OUT_DIR"

if [[ ! -f "$ISO_FILE" ]]; then
    echo "Error: ISO file not found at $ISO_FILE" >&2
    exit 1
fi

run_qemu_harvest() {
    local iso_path="$1"
    local out_path="$2"
    ISO_PATH="$iso_path" OUT_PATH="$out_path" python3 - << 'PYEOF'
import json
import os
import socket
import subprocess
import time
from PIL import Image

iso_path = os.environ["ISO_PATH"]
out_path = os.environ["OUT_PATH"]
qmp_path = f"/tmp/qmp-{os.getpid()}.sock"
if os.path.exists(qmp_path):
    os.remove(qmp_path)

qemu_cmd = [
    "qemu-system-x86_64",
    "-enable-kvm",
    "-cpu", "host",
    "-m", "2048",
    "-smp", "2",
    "-cdrom", iso_path,
    "-boot", "d",
    "-vga", "std",
    "-display", "none",
    "-qmp", f"unix:{qmp_path},server,nowait",
]

proc = subprocess.Popen(qemu_cmd)

for _ in range(50):
    if os.path.exists(qmp_path):
        break
    time.sleep(0.2)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(qmp_path)
sock_file = sock.makefile("r")

def qmp_recv():
    line = sock_file.readline()
    return json.loads(line) if line else {}

def qmp_cmd(execute, arguments=None):
    payload = {"execute": execute}
    if arguments:
        payload["arguments"] = arguments
    sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    while True:
        msg = qmp_recv()
        if "return" in msg or "error" in msg:
            return msg

def send_keys(key_names, hold_ms=100):
    keys = [{"type": "qcode", "data": k} for k in key_names]
    qmp_cmd("send-key", {"keys": keys, "hold-time": hold_ms})
    time.sleep(0.12)

def type_line(cmd_str):
    char_map = {
        " ": "spc", "/": "slash", "-": "minus", ".": "dot", "_": "shift-minus",
        "=": "equal", ";": "semicolon"
    }
    for ch in cmd_str:
        if ch in char_map:
            code = char_map[ch]
            if code.startswith("shift-"):
                send_keys(["shift", code.split("-", 1)[1]], 50)
            else:
                send_keys([code], 50)
        elif ch.isupper():
            send_keys(["shift", ch.lower()], 50)
        else:
            send_keys([ch], 50)
    send_keys(["ret"], 80)
    time.sleep(0.4)

qmp_recv()
qmp_cmd("qmp_capabilities")

def capture(ppm_name, png_name):
    ppm_path = f"/tmp/{ppm_name}"
    png_path = os.path.join(out_path, png_name)
    qmp_cmd("screendump", {"filename": ppm_path})
    time.sleep(0.3)
    im = Image.open(ppm_path)
    im.save(png_path)
    if os.path.exists(ppm_path):
        os.remove(ppm_path)
    print(f"Captured {png_path} ({im.size[0]}x{im.size[1]})")

try:
    time.sleep(4.0)
    capture("boot_menu.ppm", "vm_boot_menu.png")

    send_keys(["ret"])

    time.sleep(16.0)
    capture("installer_gui.ppm", "vm_installer_loaded.png")

    send_keys(["ctrl", "alt", "f2"], 200)
    time.sleep(2.0)
    send_keys(["ret"], 100)
    time.sleep(1.0)
    type_line("mkdir -p /cdrom")
    type_line("mount -t iso9660 -o ro /dev/sr0 /cdrom")
    type_line("uname -a")
    type_line("cat /proc/cmdline")
    type_line("cat /cdrom/preseed.cfg")
    type_line("ls -la /cdrom/proxmox-laptop")
    time.sleep(1.5)
    capture("installer_vt2.ppm", "vm_installer_preseed.png")
finally:
    try:
        qmp_cmd("quit")
    except Exception:
        pass
    proc.wait(timeout=5)
    if os.path.exists(qmp_path):
        os.remove(qmp_path)
PYEOF
}

if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if ! python3 -c "import PIL" >/dev/null 2>&1; then
        if [[ "$EUID" -eq 0 ]]; then
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends python3-pil >/dev/null
        elif sudo -n true 2>/dev/null; then
            sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends python3-pil >/dev/null
        fi
    fi
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        run_qemu_harvest "$ISO_FILE" "$OUT_DIR"
    elif sudo -n true 2>/dev/null; then
        sudo bash -c "$(declare -f run_qemu_harvest); run_qemu_harvest '$ISO_FILE' '$OUT_DIR'"
        sudo chown -f "$(id -u):$(id -g)" "${OUT_DIR}/vm_boot_menu.png" "${OUT_DIR}/vm_installer_loaded.png" "${OUT_DIR}/vm_installer_preseed.png" 2>/dev/null || true
    else
        echo "Error: /dev/kvm requires root or kvm group access." >&2
        exit 1
    fi
    exit 0
fi

docker run --rm --device /dev/kvm \
    -v "${ISO_FILE}:/iso/installer.iso:ro" \
    -v "${OUT_DIR}:/out" \
    debian:trixie-slim bash -c "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends qemu-system-x86 python3 python3-pil >/dev/null
$(declare -f run_qemu_harvest)
run_qemu_harvest /iso/installer.iso /out
"
