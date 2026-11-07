import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import { trySpawnCommandLine } from 'resource:///org/gnome/shell/misc/util.js';

const STATUS_CMD = ['/usr/local/bin/pve-laptop-status', '--json'];
const STATE_PATH = '/run/pve-wifi-nat.state';

class ProxmoxLaptopIndicator extends PanelMenu.Button {
    static {
        GObject.registerClass(this);
    }

    constructor() {
        super(0.0, 'Proxmox Laptop Assistant', false);

        this._lastLanUrl = null;
        this._currentLanUrl = 'https://127.0.0.1:8006';
        this._timeoutId = null;
        this._netMonitorId = null;
        this._stateMonitor = null;
        this._stateMonitorId = null;

        const box = new St.BoxLayout({
            style_class: 'panel-status-menu-box',
        });

        this._icon = new St.Icon({
            icon_name: 'network-server-symbolic',
            style_class: 'system-status-icon',
        });

        this._label = new St.Label({
            text: 'PVE ...',
            y_align: Clutter.ActorAlign.CENTER,
        });

        box.add_child(this._icon);
        box.add_child(this._label);
        this.add_child(box);

        this._buildMenu();
        this._startMonitors();
        this._refreshStatus(false);
    }

    _buildMenu() {
        this._lanUrlItem = new PopupMenu.PopupMenuItem('Remote URL: detecting...');
        this._lanUrlItem.connect('activate', () => {
            this._copyUrl(this._currentLanUrl);
        });
        this.menu.addMenuItem(this._lanUrlItem);

        this._wifiItem = new PopupMenu.PopupMenuItem('Wi-Fi / LAN: detecting...', {
            reactive: false,
        });
        this.menu.addMenuItem(this._wifiItem);

        this._localUrlItem = new PopupMenu.PopupMenuItem('Local URL: https://127.0.0.1:8006', {
            reactive: false,
        });
        this.menu.addMenuItem(this._localUrlItem);

        this._bridgeItem = new PopupMenu.PopupMenuItem('VM Bridge (vmbr1): detecting...', {
            reactive: false,
        });
        this.menu.addMenuItem(this._bridgeItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._pveproxyItem = new PopupMenu.PopupMenuItem('pveproxy (Web UI :8006): ...', {
            reactive: false,
        });
        this.menu.addMenuItem(this._pveproxyItem);

        this._pveClusterItem = new PopupMenu.PopupMenuItem('pve-cluster (pmxcfs): ...', {
            reactive: false,
        });
        this.menu.addMenuItem(this._pveClusterItem);

        this._pveNatItem = new PopupMenu.PopupMenuItem('pve-wifi-nat (vmbr1 NAT): ...', {
            reactive: false,
        });
        this.menu.addMenuItem(this._pveNatItem);

        this._hostStatsItem = new PopupMenu.PopupMenuItem('Host: ...', {
            reactive: false,
        });
        this.menu.addMenuItem(this._hostStatsItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this.menu.addAction('Copy Remote URL to Clipboard', () => {
            this._copyUrl(this._currentLanUrl);
        });

        this.menu.addAction('Open Proxmox Web UI in Browser', () => {
            Gio.AppInfo.launch_default_for_uri(this._currentLanUrl, null);
        });

        this.menu.addAction('Open Proxmox TUI Assistant', () => {
            this._launchTui();
        });

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this.menu.addAction('Reset Wi-Fi NAT (pve-wifi-nat)', () => {
            this._runPrivilegedAction(
                ['/usr/local/bin/pve-wifi-nat.sh'],
                'Wi-Fi NAT bridge (vmbr1) and masquerade rules reconciled.'
            );
        });

        this.menu.addAction('Restart Proxmox Web UI (pveproxy)', () => {
            this._runPrivilegedAction(
                ['systemctl', 'restart', 'pve-cluster.service', 'pveproxy.service', 'pvedaemon.service'],
                'Proxmox Web UI and cluster services restarted.'
            );
        });

        this.menu.addAction('Refresh Status Now', () => {
            this._refreshStatus(false);
        });

        this.menu.connect('open-state-changed', (_menu, isOpen) => {
            if (isOpen)
                this._refreshStatus(false);
        });
    }

    _startMonitors() {
        this._timeoutId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            this._refreshStatus(true);
            return GLib.SOURCE_CONTINUE;
        });

        const netMonitor = Gio.NetworkMonitor.get_default();
        this._netMonitorId = netMonitor.connect('network-changed', () => {
            this._refreshStatus(true);
        });

        try {
            const stateFile = Gio.File.new_for_path(STATE_PATH);
            this._stateMonitor = stateFile.monitor_file(Gio.FileMonitorFlags.NONE, null);
            this._stateMonitorId = this._stateMonitor.connect('changed', () => {
                this._refreshStatus(true);
            });
        } catch (e) {
            console.error(e);
        }
    }

    _copyUrl(url) {
        const clipboard = St.Clipboard.get_default();
        clipboard.set_text(St.ClipboardType.CLIPBOARD, url);
        clipboard.set_text(St.ClipboardType.PRIMARY, url);
        Main.notify('Proxmox Laptop Assistant', `Copied ${url} to clipboard`);
    }

    _launchTui() {
        const terminals = [
            'gnome-terminal -- /usr/local/bin/pve-laptop-tui',
            'x-terminal-emulator -e /usr/local/bin/pve-laptop-tui',
        ];
        for (const cmd of terminals) {
            try {
                trySpawnCommandLine(cmd);
                return;
            } catch (_e) {
            }
        }
    }

    _runPrivilegedAction(args, successMsg) {
        const cmd = ['sh', '-c', 'sudo -n "$@" 2>/dev/null || pkexec "$@"', '--', ...args];
        try {
            const proc = Gio.Subprocess.new(
                cmd,
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            proc.communicate_utf8_async(null, null, (p, res) => {
                try {
                    const [, , stderr] = p.communicate_utf8_finish(res);
                    if (p.get_successful())
                        Main.notify('Proxmox Laptop Assistant', successMsg);
                    else
                        Main.notifyError('Proxmox Laptop Assistant', stderr.trim() || 'Action failed');
                } catch (err) {
                    Main.notifyError('Proxmox Laptop Assistant', err.message);
                }
                this._refreshStatus(false);
            });
        } catch (err) {
            Main.notifyError('Proxmox Laptop Assistant', err.message);
        }
    }

    _refreshStatus(notifyOnSwitch) {
        try {
            const proc = Gio.Subprocess.new(
                STATUS_CMD,
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE
            );
            proc.communicate_utf8_async(null, null, (p, res) => {
                try {
                    const [, stdout] = p.communicate_utf8_finish(res);
                    if (!p.get_successful() || !stdout)
                        return;
                    const data = JSON.parse(stdout);
                    this._applyStatus(data, notifyOnSwitch);
                } catch (err) {
                    console.error(err);
                }
            });
        } catch (err) {
            console.error(err);
        }
    }

    _applyStatus(data, notifyOnSwitch) {
        const lanIp = data.lan_ip || '';
        const lanUrl = data.lan_url || '';
        const localUrl = data.local_url || 'https://127.0.0.1:8006';
        const ssid = data.ssid ? ` (${data.ssid})` : '';
        const iface = data.iface || 'offline';

        this._currentLanUrl = lanUrl || localUrl;

        if (lanIp)
            this._label.set_text(`PVE ${lanIp}:8006`);
        else
            this._label.set_text('PVE 127.0.0.1:8006');

        if (notifyOnSwitch && this._lastLanUrl !== null && lanUrl && lanUrl !== this._lastLanUrl) {
            Main.notify(
                'Proxmox Wi-Fi / LAN Updated',
                `Access from other devices on ${iface}${ssid} via ${lanUrl}`
            );
        }
        this._lastLanUrl = lanUrl;

        this._lanUrlItem.label.set_text(
            lanUrl
                ? `Remote URL (Click to Copy): ${lanUrl}`
                : 'Remote URL: Offline (Connect Wi-Fi for LAN access)'
        );
        this._wifiItem.label.set_text(`Wi-Fi / LAN Interface: ${iface}${ssid}`);
        this._localUrlItem.label.set_text(`Local Host URL: ${localUrl}`);
        this._bridgeItem.label.set_text(
            `VM Bridge (vmbr1): ${data.vmbr1_ip || 'missing'} (NAT: ${data.nat_rule || 'unknown'})`
        );

        const mark = state => (state === 'active' ? '●' : '○');
        this._pveproxyItem.label.set_text(
            `${mark(data.pveproxy)} pveproxy (Web UI :8006): ${data.pveproxy}`
        );
        this._pveClusterItem.label.set_text(
            `${mark(data.pve_cluster)} pve-cluster (pmxcfs): ${data.pve_cluster}`
        );
        this._pveNatItem.label.set_text(
            `${mark(data.pve_wifi_nat)} pve-wifi-nat (vmbr1 NAT): ${data.pve_wifi_nat}`
        );
        this._hostStatsItem.label.set_text(
            `Host: Load ${data.load_avg} | RAM ${data.mem_used_gb}/${data.mem_total_gb} GiB (${data.mem_pct}%) | VMs ${data.vms_running} | CTs ${data.cts_running}`
        );
    }

    destroy() {
        if (this._timeoutId) {
            GLib.Source.remove(this._timeoutId);
            this._timeoutId = null;
        }
        if (this._netMonitorId) {
            Gio.NetworkMonitor.get_default().disconnect(this._netMonitorId);
            this._netMonitorId = null;
        }
        if (this._stateMonitor && this._stateMonitorId) {
            this._stateMonitor.disconnect(this._stateMonitorId);
            this._stateMonitor.cancel();
            this._stateMonitorId = null;
            this._stateMonitor = null;
        }
        super.destroy();
    }
}

export default class ProxmoxLaptopExtension extends Extension {
    enable() {
        this._indicator = new ProxmoxLaptopIndicator();
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
