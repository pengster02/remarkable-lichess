#!/usr/bin/env python3
from struct import unpack

from websocket import WebSocketException, create_connection


def display_ready():
    # An HTTP check can pass before x11vnc starts. A direct connection to
    # x11vnc would bypass the proxy that browsers use.
    client = create_connection("ws://127.0.0.1:6080/websockify", subprotocols=["binary"],
                               http_no_proxy=["127.0.0.1"], timeout=1)
    pending = bytearray()

    def read(size):
        while len(pending) < size:
            packet = client.recv()
            if not isinstance(packet, bytes):
                raise EOFError("VNC connection closed or sent a text frame")
            pending.extend(packet)
        result = pending[:size]
        del pending[:size]
        return result

    try:
        # The bundled x11vnc uses RFB 3.8 with no authentication. A greeting
        # alone misses negotiation failures, while requesting pixels would
        # copy the framebuffer at every health check.
        version = b"RFB 003.008\n"
        if read(len(version)) != version:
            return False
        client.send_binary(version)

        security_count = read(1)[0]
        no_auth = b"\x01"
        if no_auth[0] not in read(security_count):
            return False
        client.send_binary(no_auth)
        if read(4) != bytes(4):
            return False

        client.send_binary(b"\x01")  # Keep other clients connected.
        width, height, name_length = unpack(">HH16xI", read(24))
        if not width or not height:
            return False
        read(name_length)
        return True
    finally:
        client.close(timeout=0)


if __name__ == "__main__":
    try:
        raise SystemExit(0 if display_ready() else 1)
    except (EOFError, OSError, WebSocketException):
        raise SystemExit(1)
