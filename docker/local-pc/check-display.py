#!/usr/bin/env python3
import re

from websockify.websocket import WebSocket, WebSocketWantReadError


def display_ready():
    # Use the browser's proxy path. An HTTP page check or direct RFB probe
    # would miss failures between websockify and x11vnc.
    client = WebSocket()
    while True:
        try:
            client.connect("ws://127.0.0.1:6080/websockify", protocols=["binary"])
            break
        except WebSocketWantReadError:
            continue

    # Ubuntu's websockify 0.10 client raises while masking its close frame.
    with client.socket:
        greeting = b""
        while len(greeting) < 12:
            try:
                data = client.recvmsg()
            except WebSocketWantReadError:
                continue
            if data is None:
                return False
            greeting += data
        return re.fullmatch(rb"RFB 003\.[0-9]{3}\n", greeting[:12]) is not None


if __name__ == "__main__":
    raise SystemExit(0 if display_ready() else 1)
