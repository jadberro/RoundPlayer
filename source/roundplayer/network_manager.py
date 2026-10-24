#!/usr/bin/env python3
"""
Round Media Player - Wi-Fi / network control via NetworkManager (nmcli).

Used by playback_manager.py (/api/network/*) so both the HUD settings deck and the web remote can
show the current network, scan, join a network, forget one, and fall back to a setup hotspot.

Requires: NetworkManager (default on Raspberry Pi OS Bookworm/Trixie) and a polkit rule letting the
daemon's user manage connections without a password (install_pi.sh writes
/etc/polkit-1/rules.d/50-roundplayer-network.rules).
"""
import json
import re
import shutil
import socket
import subprocess
import threading
import time
from typing import Any, Dict, List, Optional

WIFI_COUNTRY = "GB"              # regulatory domain: without it the Pi's radio never uses 5 GHz
PREF_FILE = "/data/roundplayer_wifi.json"   # {"band": "auto"|"5"|"2.4", "hotspot_band": "5"|"2.4"}
HOTSPOT_SSID = "RoundPlayer-Setup"
HOTSPOT_PSK = "roundplayer"
HOTSPOT_CON = "roundplayer-hotspot"
_WIFI_IFACE: Optional[str] = None
_lock = threading.Lock()


def _nmcli(*args: str, timeout: float = 20.0) -> subprocess.CompletedProcess:
    return subprocess.run(["nmcli", "-t", "--escape", "no", *args], capture_output=True, text=True, timeout=timeout)


def available() -> bool:
    return shutil.which("nmcli") is not None


def _prefs() -> Dict[str, Any]:
    try:
        return json.load(open(PREF_FILE))
    except Exception:
        return {"band": "5", "hotspot_band": "5"}


def set_prefs(**kw) -> Dict[str, Any]:
    p = _prefs(); p.update({k: v for k, v in kw.items() if v is not None})
    try:
        import os
        os.makedirs(os.path.dirname(PREF_FILE), exist_ok=True)
        json.dump(p, open(PREF_FILE, "w"))
    except Exception:
        pass
    return p


def regdomain() -> Dict[str, Any]:
    """Current regulatory domain and whether 5 GHz is usable."""
    info: Dict[str, Any] = {"country": None, "five_ghz": False}
    try:
        out = subprocess.run(["iw", "reg", "get"], capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"country (\w\w):", out)
        info["country"] = m.group(1) if m else None
        # "98" = kernel intersection of a user-set domain and the driver's own table: 5 GHz is allowed
        info["five_ghz"] = bool(info["country"]) and info["country"] != "00"
        # does the adapter list any 5 GHz channels as usable?
        out2 = subprocess.run(["iw", "phy"], capture_output=True, text=True, timeout=5).stdout
        info["adapter_5ghz_channels"] = len(re.findall(r"\* 5\d{3}(?:\.\d)? MHz \[\d+\] \([\d.]+ dBm\)", out2))
    except Exception as e:
        info["error"] = str(e)
    return info


def ensure_regdomain(country: str = WIFI_COUNTRY) -> Dict[str, Any]:
    """Set the Wi-Fi country so 5 GHz channels are allowed (persisted by install_pi.sh via raspi-config; this is the
    runtime fallback). Needs the sudoers rule for `iw`."""
    cur = regdomain()
    if cur.get("country") in (None, "00"):
        subprocess.run(["sudo", "-n", "iw", "reg", "set", country], capture_output=True, timeout=5)
        subprocess.run(["sudo", "-n", "rfkill", "unblock", "wifi"], capture_output=True, timeout=5)
        cur = regdomain()
    disable_powersave()
    return cur


def disable_powersave() -> bool:
    """Disable Wi-Fi power save on all wireless connections and interfaces to prevent dropouts on Pi 4."""
    try:
        iface = wifi_iface()
        if iface:
            subprocess.run(["sudo", "-n", "iw", iface, "set", "power_save", "off"], capture_output=True, timeout=5)
        for c in saved():
            _nmcli("connection", "modify", c["name"], "802-11-wireless.powersave", "2")
        return True
    except Exception:
        return False


def wifi_iface() -> Optional[str]:
    global _WIFI_IFACE
    if _WIFI_IFACE:
        return _WIFI_IFACE
    try:
        out = _nmcli("-f", "DEVICE,TYPE", "device").stdout
        for line in out.splitlines():
            dev, typ = (line.split(":") + [""])[:2]
            if typ == "wifi":
                _WIFI_IFACE = dev
                return dev
    except Exception:
        pass
    return None


def _lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def status() -> Dict[str, Any]:
    """Current connectivity summary for the HUD / remote."""
    if not available():
        return {"available": False, "error": "NetworkManager (nmcli) not installed"}
    result: Dict[str, Any] = {
        "available": True, "wifi": None, "ethernet": None, "ip": _lan_ip(),
        "hostname": socket.gethostname(), "hotspot": False, "devices": [],
        "regdomain": regdomain(), "prefs": _prefs(),
    }
    try:
        out = _nmcli("-f", "DEVICE,TYPE,STATE,CONNECTION", "device").stdout
        for line in out.splitlines():
            parts = (line.split(":") + ["", "", "", ""])[:4]
            dev, typ, state, con = parts
            if typ in ("loopback",):
                continue
            result["devices"].append({"device": dev, "type": typ, "state": state, "connection": con})
            if typ == "ethernet" and state.startswith("connected"):
                result["ethernet"] = {"device": dev, "connection": con}
            if typ == "wifi":
                result["wifi"] = {"device": dev, "state": state, "connection": con or None,
                                  "ssid": None, "signal": None, "security": None}
                if con == HOTSPOT_CON:
                    result["hotspot"] = True
        if result["wifi"] and result["wifi"]["state"].startswith("connected"):
            act = _nmcli("-f", "ACTIVE,SSID,SIGNAL,SECURITY,FREQ", "device", "wifi", "list", "--rescan", "no").stdout
            for line in act.splitlines():
                p = (line.split(":") + [""] * 5)[:5]
                if p[0] == "yes":
                    result["wifi"].update({"ssid": p[1], "signal": int(p[2] or 0), "security": p[3] or "open",
                                           "band": "5 GHz" if p[4].startswith("5") else "2.4 GHz"})
                    break
    except Exception as e:
        result["error"] = str(e)
    return result


def scan(rescan: bool = True) -> List[Dict[str, Any]]:
    """Visible networks, strongest first, de-duplicated by SSID."""
    if not available():
        return []
    with _lock:
        out = _nmcli("-f", "SSID,SIGNAL,SECURITY,FREQ,ACTIVE,IN-USE", "device", "wifi", "list",
                     "--rescan", "yes" if rescan else "no", timeout=30).stdout
    known = {c["ssid"] for c in saved()}
    best: Dict[str, Dict[str, Any]] = {}
    for line in out.splitlines():
        p = (line.split(":") + [""] * 6)[:6]
        ssid = p[0]
        if not ssid:
            continue
        entry = {
            "ssid": ssid, "signal": int(p[1] or 0), "security": p[2] or "open",
            "band": "5 GHz" if p[3].startswith("5") else "2.4 GHz",
            "active": p[4] == "yes" or p[5].strip() == "*", "saved": ssid in known,
            "secured": bool(p[2]) and p[2] != "--",
        }
        entry["freq_mhz"] = int(p[3].split()[0]) if p[3].split() and p[3].split()[0].isdigit() else None
        k = (ssid, entry["band"])
        if k not in best or entry["signal"] > best[k]["signal"] or entry["active"]:
            best[k] = entry
    # 5 GHz first when both bands of the same SSID are visible and the signal is usable
    return sorted(best.values(), key=lambda e: (not e["active"], e["band"] != "5 GHz" if e["signal"] >= 35 else True, -e["signal"]))


def saved() -> List[Dict[str, Any]]:
    """Saved Wi-Fi connections (profiles)."""
    if not available():
        return []
    out = _nmcli("-f", "NAME,TYPE,UUID", "connection", "show").stdout
    res = []
    for line in out.splitlines():
        p = (line.split(":") + ["", "", ""])[:3]
        if p[1] in ("802-11-wireless", "wifi") and p[0] != HOTSPOT_CON:
            ssid = p[0]
            try:
                s = _nmcli("-g", "802-11-wireless.ssid", "connection", "show", p[0]).stdout.strip()
                if s:
                    ssid = s
            except Exception:
                pass
            res.append({"name": p[0], "ssid": ssid, "uuid": p[2]})
    return res


def _band_arg(band: Optional[str]) -> Optional[str]:
    b = (band or _prefs().get("band") or "auto")
    return {"5": "a", "5 GHz": "a", "a": "a", "2.4": "bg", "2.4 GHz": "bg", "bg": "bg"}.get(str(b))


def connect(ssid: str, psk: Optional[str] = None, hidden: bool = False, band: Optional[str] = None) -> Dict[str, Any]:
    """
    Join a network. Leaves the hotspot if active. On failure, tries to restore the previous connection.
    Blocks up to ~45 s.
    """
    if not available():
        return {"status": "error", "message": "NetworkManager not available"}
    iface = wifi_iface()
    if not iface:
        return {"status": "error", "message": "No Wi-Fi interface"}
    prev = status().get("wifi") or {}
    prev_con = prev.get("connection")
    with _lock:
        if prev_con == HOTSPOT_CON:
            _nmcli("connection", "down", HOTSPOT_CON)
        # Reuse a saved profile when there is one for this SSID and no new password was given
        profile = next((c["name"] for c in saved() if c["ssid"] == ssid), None)
        band_arg = _band_arg(band)
        if profile and not psk:
            if band_arg:
                _nmcli("connection", "modify", profile, "802-11-wireless.band", band_arg)
            else:
                _nmcli("connection", "modify", profile, "802-11-wireless.band", "")
            r = _nmcli("connection", "up", profile, timeout=45)
            if r.returncode != 0 and band_arg:
                # the SSID may only exist on the other band here - drop the restriction and retry
                _nmcli("connection", "modify", profile, "802-11-wireless.band", "")
                r = _nmcli("connection", "up", profile, timeout=45)
        else:
            if profile:
                _nmcli("connection", "delete", profile)
            args = ["device", "wifi", "connect", ssid, "ifname", iface]
            if psk:
                args += ["password", psk]
            if hidden:
                args += ["hidden", "yes"]
            r = _nmcli(*args, timeout=45)
            if r.returncode == 0 and band_arg:
                # lock the new profile to the preferred band if that band is actually visible for this SSID
                visible = {n["band"] for n in scan(rescan=False) if n["ssid"] == ssid}
                if (band_arg == "a" and "5 GHz" in visible) or (band_arg == "bg" and "2.4 GHz" in visible):
                    prof = next((c["name"] for c in saved() if c["ssid"] == ssid), None)
                    if prof:
                        _nmcli("connection", "modify", prof, "802-11-wireless.band", band_arg)
                        _nmcli("connection", "up", prof, timeout=45)
    if r.returncode == 0:
        disable_powersave()
        time.sleep(1.5)
        return {"status": "ok", "ssid": ssid, "ip": _lan_ip(), "network": status()}
    msg = (r.stderr or r.stdout).strip()
    # Roll back so the box doesn't end up offline after a typo in the password
    if prev_con and prev_con != HOTSPOT_CON:
        _nmcli("connection", "up", prev_con, timeout=30)
    elif prev_con == HOTSPOT_CON:
        hotspot(True)
    return {"status": "error", "message": msg or "connection failed", "network": status()}


def forget(ssid: str) -> Dict[str, Any]:
    removed = 0
    for c in saved():
        if c["ssid"] == ssid or c["name"] == ssid:
            _nmcli("connection", "delete", c["name"])
            removed += 1
    return {"status": "ok", "removed": removed}


def hotspot(enable: bool) -> Dict[str, Any]:
    """Setup access point so a phone can reach the web remote when there is no known network."""
    if not available():
        return {"status": "error", "message": "NetworkManager not available"}
    iface = wifi_iface()
    if not iface:
        return {"status": "error", "message": "No Wi-Fi interface"}
    with _lock:
        if enable:
            exists = any(c["name"] == HOTSPOT_CON for c in _all_connections())
            if not exists:
                five = str(_prefs().get("hotspot_band", "5")) == "5" and regdomain().get("five_ghz")
                band_args = ["band", "a", "channel", "36"] if five else ["band", "bg", "channel", "6"]
                r = _nmcli("device", "wifi", "hotspot", "ifname", iface, "con-name", HOTSPOT_CON,
                           "ssid", HOTSPOT_SSID, "password", HOTSPOT_PSK, *band_args, timeout=30)
                if r.returncode != 0 and five:  # some firmware refuses 5 GHz AP - fall back to 2.4
                    _nmcli("connection", "delete", HOTSPOT_CON)
                    r = _nmcli("device", "wifi", "hotspot", "ifname", iface, "con-name", HOTSPOT_CON,
                               "ssid", HOTSPOT_SSID, "password", HOTSPOT_PSK, "band", "bg", "channel", "6", timeout=30)
            else:
                r = _nmcli("connection", "up", HOTSPOT_CON, timeout=30)
        else:
            r = _nmcli("connection", "down", HOTSPOT_CON, timeout=30)
    ok = r.returncode == 0
    return {"status": "ok" if ok else "error", "message": (r.stderr or r.stdout).strip(),
            "ssid": HOTSPOT_SSID, "password": HOTSPOT_PSK, "enabled": enable and ok}


def _all_connections() -> List[Dict[str, str]]:
    out = _nmcli("-f", "NAME,TYPE", "connection", "show").stdout
    return [{"name": l.split(":")[0], "type": (l.split(":") + [""])[1]} for l in out.splitlines() if l]


def watchdog_loop(check_every_s: int = 60, offline_grace_s: int = 180):
    """
    Background thread: if there is no connectivity for `offline_grace_s`, bring up the setup hotspot so
    the player is still reachable. Drops the hotspot again once a saved network is reachable.
    """
    offline_since: Optional[float] = None
    try:
        ensure_regdomain()
    except Exception:
        pass
    while True:
        try:
            st = status()
            online = bool(st.get("ethernet")) or bool((st.get("wifi") or {}).get("ssid")) and not st.get("hotspot")
            if online:
                offline_since = None
            elif not st.get("hotspot"):
                offline_since = offline_since or time.time()
                if time.time() - offline_since > offline_grace_s:
                    hotspot(True)
            elif st.get("hotspot"):
                # Every few minutes, see if a saved network came back
                for net in scan(rescan=True):
                    if net["saved"]:
                        connect(net["ssid"])
                        break
        except Exception:
            pass
        time.sleep(check_every_s)


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1:] or ["status"]
    if cmd[0] == "status":
        print(json.dumps(status(), indent=2))
    elif cmd[0] == "scan":
        print(json.dumps(scan(), indent=2))
    elif cmd[0] == "connect":
        print(json.dumps(connect(cmd[1], cmd[2] if len(cmd) > 2 else None), indent=2))
    elif cmd[0] == "forget":
        print(json.dumps(forget(cmd[1]), indent=2))
    elif cmd[0] == "hotspot":
        print(json.dumps(hotspot(cmd[1] != "off"), indent=2))
