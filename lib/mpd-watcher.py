#!/usr/bin/env python3
"""
Mark II MPD state watcher.
Polls MPD via TCP, extracts current track info and albumart,
writes /tmp/mark2-mpd-state.json for the kiosk HUD to read.

JSON format:
  { "state": "play|pause|stop", "title": "...", "artist": "...",
    "album": "...", "coverart": "data:image/jpeg;base64,..." }
"""
import socket
import json
import base64
import time
import os

MPD_HOST = "localhost"
MPD_PORT = 6600
OUT_FILE = "/tmp/mark2-mpd-state.json"
POLL_INTERVAL = 2.0


def mpd_connect():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3.0)
    s.connect((MPD_HOST, MPD_PORT))
    banner = s.recv(256).decode("utf-8", errors="ignore")
    if not banner.startswith("OK MPD"):
        raise IOError("Not MPD")
    return s


def mpd_cmd(s, cmd):
    s.sendall((cmd + "\n").encode())
    resp = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        resp += chunk
        if b"\nOK\n" in resp or resp.endswith(b"OK\n") or b"\nACK " in resp:
            break
    return resp.decode("utf-8", errors="ignore")


def parse_pairs(text):
    d = {}
    for line in text.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            d[k.lower()] = v
    return d


def get_albumart(s, uri):
    """Fetch albumart via MPD readpicture command, return base64 data URI."""
    try:
        offset = 0
        data = b""
        mime = "image/jpeg"
        while True:
            s.sendall(f"readpicture \"{uri}\" {offset}\n".encode())
            resp = b""
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                resp += chunk
                if b"\nOK\n" in resp or resp.endswith(b"OK\n") or b"\nACK " in resp:
                    break

            if b"\nACK " in resp or b"size: 0" in resp:
                return None

            lines = resp.split(b"\n")
            binary_start = 0
            size = 0
            for i, line in enumerate(lines):
                decoded = line.decode("utf-8", errors="ignore")
                if decoded.startswith("Size: "):
                    size = int(decoded.split(": ")[1])
                elif decoded.startswith("Type: "):
                    mime = decoded.split(": ")[1].strip()
                elif decoded.startswith("Binary: "):
                    binary_len = int(decoded.split(": ")[1])
                    binary_start = sum(len(l) + 1 for l in lines[:i+1])
                    break

            if binary_start == 0:
                break

            chunk_data = resp[binary_start:binary_start + binary_len]
            data += chunk_data
            offset += binary_len

            if size > 0 and len(data) >= size:
                break
            if binary_len == 0:
                break

        if not data:
            return None

        b64 = base64.b64encode(data).decode("ascii")
        return f"data:{mime};base64,{b64}"
    except Exception:
        return None


def write_state(state):
    tmp = OUT_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, OUT_FILE)


def main():
    last_uri = None
    last_coverart = None

    while True:
        try:
            s = mpd_connect()
            try:
                status = parse_pairs(mpd_cmd(s, "status"))
                play_state = status.get("state", "stop")

                if play_state == "play":
                    song = parse_pairs(mpd_cmd(s, "currentsong"))
                    uri = song.get("file", "")
                    title  = song.get("title",  "")
                    artist = song.get("artist", "")
                    album  = song.get("album",  "")

                    # Only re-fetch coverart if track changed
                    if uri != last_uri:
                        last_uri = uri
                        last_coverart = get_albumart(s, uri) if uri else None

                    write_state({
                        "state":    play_state,
                        "title":    title,
                        "artist":   artist,
                        "album":    album,
                        "coverart": last_coverart,
                    })
                else:
                    last_uri = None
                    last_coverart = None
                    write_state({"state": play_state})

            finally:
                s.close()

        except Exception as e:
            write_state({"state": "stop", "error": str(e)})

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
