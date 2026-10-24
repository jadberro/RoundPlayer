#!/usr/bin/env python3
"""
Round Media Player - DIAL Server (YouTube 'Watch on TV' Receiver)
Implements SSDP multicast discovery and standard DIAL REST protocol on Port 8008.
Advertises friendly name 'Living Room Player' to mobile YouTube apps.
"""

import socket
import struct
import threading
import http.server
import socketserver
import urllib.parse
import urllib.request
import json
import uuid
import re

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
HTTP_PORT = 8008
DEVICE_UUID = "e2c34a10-7e8b-4b2a-8d19-3f7a6b8c9d0e"
FRIENDLY_NAME = "Living Room Player"
MANUFACTURER = "Raspberry Pi"
MODEL_NAME = "Round Media Player"
PLAYBACK_MANAGER_URL = "http://127.0.0.1:8000"

def get_local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

LOCAL_IP = get_local_ip()

SSDP_REPLY_TEMPLATE = (
    "HTTP/1.1 200 OK\r\n"
    "CACHE-CONTROL: max-age=1800\r\n"
    "EXT:\r\n"
    "LOCATION: http://{local_ip}:{http_port}/dd.xml\r\n"
    "SERVER: Linux/6.6 UPnP/1.1 DialServer/1.0\r\n"
    "ST: urn:dial-multiscreen-org:service:dial:1\r\n"
    "USN: uuid:{uuid}::urn:dial-multiscreen-org:service:dial:1\r\n"
    "BOOTID.UPNP.ORG: 1\r\n"
    "CONFIGID.UPNP.ORG: 1\r\n\r\n"
)

DD_XML_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <device>
    <deviceType>urn:dial-multiscreen-org:device:dial:1</deviceType>
    <friendlyName>{friendly_name}</friendlyName>
    <manufacturer>{manufacturer}</manufacturer>
    <modelName>{model_name}</modelName>
    <UDN>uuid:{uuid}</UDN>
    <serviceList>
      <service>
        <serviceType>urn:dial-multiscreen-org:service:dial:1</serviceType>
        <serviceId>urn:dial-multiscreen-org:serviceId:dial</serviceId>
        <controlURL>/apps</controlURL>
        <eventSubURL></eventSubURL>
        <SCPDURL></SCPDURL>
      </service>
    </serviceList>
  </device>
</root>"""

class DIALRequestHandler(http.server.BaseHTTPRequestHandler):
    def end_headers(self):
        # DIAL spec requires Application-URL header
        self.send_header('Application-URL', f'http://{LOCAL_IP}:{HTTP_PORT}/apps/')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Origin')
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        if self.path == '/dd.xml' or self.path == '/description.xml':
            xml_data = DD_XML_TEMPLATE.format(
                friendly_name=FRIENDLY_NAME,
                manufacturer=MANUFACTURER,
                model_name=MODEL_NAME,
                uuid=DEVICE_UUID
            ).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/xml; charset=utf-8')
            self.send_header('Content-Length', str(len(xml_data)))
            self.end_headers()
            self.wfile.write(xml_data)

        elif self.path.startswith('/apps/YouTube'):
            state_xml = (
                '<?xml version="1.0" encoding="UTF-8"?>\r\n'
                '<service xmlns="urn:dial-multiscreen-org:schemas:dial">\r\n'
                '  <name>YouTube</name>\r\n'
                '  <options allowStop="true"/>\r\n'
                '  <state>running</state>\r\n'
                '  <link rel="run" href="run"/>\r\n'
                '</service>\r\n'
            ).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/xml; charset=utf-8')
            self.send_header('Content-Length', str(len(state_xml)))
            self.end_headers()
            self.wfile.write(state_xml)

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path.startswith('/apps/YouTube'):
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8', errors='ignore')
            print(f"[DIAL] Received YouTube launch payload: {body}")

            # Extract video ID from payload (v=... or pairing)
            video_id = None
            parsed = urllib.parse.parse_qs(body)
            if 'v' in parsed:
                video_id = parsed['v'][0]
            elif 'videoId' in parsed:
                video_id = parsed['videoId'][0]
            else:
                # Regex match for 11-char YouTube ID
                m = re.search(r'[?&]v=([a-zA-Z0-9_-]{11})', body)
                if not m:
                    m = re.search(r'([a-zA-Z0-9_-]{11})', body)
                if m:
                    video_id = m.group(1)

            if video_id:
                print(f"[DIAL] Extracted video ID: {video_id}. Forwarding to Playback Manager...")
                try:
                    # Trigger cache and play in Playback Manager
                    req = urllib.request.Request(
                        f"{PLAYBACK_MANAGER_URL}/api/cache/{video_id}",
                        data=b'',
                        method='POST'
                    )
                    urllib.request.urlopen(req, timeout=3)

                    req_play = urllib.request.Request(
                        f"{PLAYBACK_MANAGER_URL}/api/play/{video_id}",
                        data=b'',
                        method='POST'
                    )
                    urllib.request.urlopen(req_play, timeout=3)
                except Exception as e:
                    print(f"[DIAL] Failed to contact playback manager: {e}")

            # Return 201 Created with Location header per DIAL spec
            self.send_response(201)
            self.send_header('Location', f'http://{LOCAL_IP}:{HTTP_PORT}/apps/YouTube/run')
            self.send_header('Content-Length', '0')
            self.end_headers()

        else:
            self.send_response(404)
            self.end_headers()

    def do_DELETE(self):
        if self.path.startswith('/apps/YouTube'):
            print("[DIAL] Received YouTube stop command.")
            try:
                cmd_data = json.dumps({"action": "pause"}).encode('utf-8')
                req = urllib.request.Request(
                    f"{PLAYBACK_MANAGER_URL}/api/control",
                    data=cmd_data,
                    headers={'Content-Type': 'application/json'},
                    method='POST'
                )
                urllib.request.urlopen(req, timeout=3)
            except Exception as e:
                print(f"[DIAL] Error stopping playback: {e}")

            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Quiet standard HTTP access logs
        return

def run_ssdp_responder():
    """Listens on 239.255.255.250:1900 and responds to DIAL M-SEARCH packets."""
    ssdp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    ssdp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    
    # Handle SO_REUSEPORT if available
    try:
        ssdp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except Exception:
        pass

    try:
        ssdp_sock.bind(('', SSDP_PORT))
    except Exception as e:
        print(f"[SSDP] Bind error on port {SSDP_PORT}: {e}")
        return

    # Join multicast group on all interfaces
    mreq = struct.pack("4sl", socket.inet_aton(SSDP_ADDR), socket.INADDR_ANY)
    try:
        ssdp_sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    except Exception as e:
        print(f"[SSDP] Multicast membership error: {e}")

    print(f"[SSDP] Listening for DIAL M-SEARCH requests on {SSDP_ADDR}:{SSDP_PORT}...")

    reply = SSDP_REPLY_TEMPLATE.format(
        local_ip=LOCAL_IP,
        http_port=HTTP_PORT,
        uuid=DEVICE_UUID
    ).encode('utf-8')

    while True:
        try:
            data, addr = ssdp_sock.recvfrom(2048)
            msg = data.decode('utf-8', errors='ignore')
            if 'M-SEARCH' in msg and ('urn:dial-multiscreen-org:service:dial:1' in msg or 'ssdp:all' in msg):
                # Send unicast reply directly to requesting client
                ssdp_sock.sendto(reply, addr)
        except Exception:
            pass

def main():
    print(f"=== Round Media Player DIAL Server ===")
    print(f"Device Name: '{FRIENDLY_NAME}'")
    print(f"Local IP:    {LOCAL_IP}")
    print(f"DIAL Port:   {HTTP_PORT}")

    ssdp_thread = threading.Thread(target=run_ssdp_responder, daemon=True)
    ssdp_thread.start()

    class ReusableTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True

    with ReusableTCPServer(("", HTTP_PORT), DIALRequestHandler) as httpd:
        print(f"[DIAL] HTTP service live at http://{LOCAL_IP}:{HTTP_PORT}/dd.xml")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[DIAL] Shutting down.")

if __name__ == '__main__':
    main()
