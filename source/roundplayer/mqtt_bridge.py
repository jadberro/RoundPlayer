"""
mqtt_bridge.py - Home Assistant / MQTT integration for the Round Media Player.

settings.mqtt = {"enabled": true, "host": "homeassistant.local", "port": 1883, "username": "", "password": "", "base": "roundplayer"}

Publishes (retained) HA discovery for: a sensor (now playing, with attributes), a switch (play/pause), a number
(volume 0..100), buttons (next, previous, sleep), and a sensor for the sleep timer. State on <base>/state every
2 s when it changed; commands on <base>/cmd/<entity>. Availability on <base>/availability (LWT).
"""
import json, threading, time
from typing import Any, Callable, Dict, Optional

_thread: Optional[threading.Thread] = None
_stop = threading.Event()


def start(get_state: Callable[[], Dict[str, Any]], on_command: Callable[[str, Any], None], cfg: Dict[str, Any]) -> bool:
    global _thread
    stop()
    if not cfg or not cfg.get("enabled") or not cfg.get("host"):
        return False
    try:
        import paho.mqtt.client as mqtt  # noqa: F401
    except Exception as e:
        print(f"[MQTT] paho-mqtt not installed: {e}")
        return False
    _stop.clear()
    _thread = threading.Thread(target=_run, args=(get_state, on_command, cfg), daemon=True, name="mqtt-bridge")
    _thread.start()
    return True


def stop() -> None:
    _stop.set()


def _run(get_state, on_command, cfg):
    import paho.mqtt.client as mqtt
    base = cfg.get("base") or "roundplayer"
    avail = f"{base}/availability"
    dev = {"identifiers": [f"{base}_pi"], "name": "Round Player", "manufacturer": "Round Media Player", "model": "Raspberry Pi 4 + DAC Pro"}

    def disc(component: str, obj: str, extra: Dict[str, Any]) -> tuple:
        uid = f"{base}_{obj}"
        payload = {"unique_id": uid, "name": extra.pop("name"), "availability_topic": avail, "device": dev, **extra}
        return (f"homeassistant/{component}/{uid}/config", json.dumps(payload))

    discovery = [
        disc("sensor", "now_playing", {"name": "Round Player now playing", "state_topic": f"{base}/state", "value_template": "{{ value_json.title }}",
                                       "json_attributes_topic": f"{base}/state", "icon": "mdi:music-circle"}),
        disc("switch", "playing", {"name": "Round Player play", "state_topic": f"{base}/state", "value_template": "{{ 'ON' if value_json.is_playing else 'OFF' }}",
                                   "command_topic": f"{base}/cmd/playing", "payload_on": "ON", "payload_off": "OFF", "icon": "mdi:play-pause"}),
        disc("number", "volume", {"name": "Round Player volume", "state_topic": f"{base}/state", "value_template": "{{ value_json.volume | round(0) }}",
                                  "command_topic": f"{base}/cmd/volume", "min": 0, "max": 100, "step": 1, "icon": "mdi:volume-high"}),
        disc("button", "next", {"name": "Round Player next", "command_topic": f"{base}/cmd/next", "icon": "mdi:skip-next"}),
        disc("button", "previous", {"name": "Round Player previous", "command_topic": f"{base}/cmd/previous", "icon": "mdi:skip-previous"}),
        disc("button", "sleep", {"name": "Round Player sleep", "command_topic": f"{base}/cmd/sleep", "icon": "mdi:power-sleep"}),
        disc("sensor", "sleep_timer", {"name": "Round Player sleep timer", "state_topic": f"{base}/state", "value_template": "{{ value_json.sleep_in_min }}",
                                       "unit_of_measurement": "min", "icon": "mdi:timer-sand"}),
    ]

    client = mqtt.Client(client_id=f"{base}-{int(time.time())}") if not hasattr(mqtt, "CallbackAPIVersion") else mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id=f"{base}-{int(time.time())}")
    if cfg.get("username"):
        client.username_pw_set(cfg["username"], cfg.get("password") or None)
    client.will_set(avail, "offline", retain=True)

    def on_connect(c, userdata, flags, rc):
        print(f"[MQTT] connected rc={rc}")
        c.publish(avail, "online", retain=True)
        for topic, payload in discovery:
            c.publish(topic, payload, retain=True)
        c.subscribe(f"{base}/cmd/#")

    def on_message(c, userdata, msg):
        ent = msg.topic.rsplit("/", 1)[-1]
        val = msg.payload.decode("utf-8", "replace")
        try:
            on_command(ent, val)
        except Exception as e:
            print(f"[MQTT] command {ent}={val!r} failed: {e}")

    client.on_connect = on_connect
    client.on_message = on_message
    try:
        client.connect(cfg["host"], int(cfg.get("port") or 1883), keepalive=60)
    except Exception as e:
        print(f"[MQTT] connect failed: {e}")
        return
    client.loop_start()
    last = None
    try:
        while not _stop.is_set():
            try:
                st = get_state()
                blob = json.dumps(st, sort_keys=True)
                if blob != last:
                    client.publish(f"{base}/state", blob, retain=True)
                    last = blob
            except Exception as e:
                print(f"[MQTT] publish failed: {e}")
            _stop.wait(2.0)
    finally:
        try:
            client.publish(avail, "offline", retain=True)
            client.loop_stop()
            client.disconnect()
        except Exception:
            pass
