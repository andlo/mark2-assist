#!/usr/bin/env python3
"""
Mark II hardware button volume control.
Listens on /dev/input/event0 for KEY_VOLUMEUP/KEY_VOLUMEDOWN/KEY_MICMUTE.
Controls TAS5806 amplifier via I2C. Step=5% per press.
"""
import os, json, time, subprocess, signal, sys
import evdev, smbus2

DEVICE   = "/dev/input/event0"
VOL_FILE = "/tmp/mark2-volume.json"
TAS_ADDR = 0x2f
TAS_VOL  = 0x4c
TAS_MAX  = 84    # register at 100% = -42dB (max safe for Mark II 5W speaker)
TAS_MIN  = 210   # register at 0% (near silence)
STEP     = 5     # percent per button press
DEFAULT  = 60    # restore level after unmute (60% log = reg 0x79 = -60.5dB)

from math import log as _log, exp as _exp
def pct_to_reg(p):
    p = max(0, min(100, p))
    if p == 0: return TAS_MIN
    pval = (p/100.0) * (_log(TAS_MAX) - _log(TAS_MIN)) + _log(TAS_MIN)
    return round(_exp(pval))
def reg_to_pct(r):
    r = max(TAS_MAX, min(TAS_MIN, r))
    return round(100.0 * (_log(TAS_MIN) - _log(r)) / (_log(TAS_MIN) - _log(TAS_MAX)))

def get_vol(bus): return reg_to_pct(bus.read_byte_data(TAS_ADDR, TAS_VOL))

def set_vol(bus, pct):
    pct = max(0, min(100, pct))
    bus.write_byte_data(TAS_ADDR, TAS_VOL, pct_to_reg(pct))
    subprocess.run(["amixer","set","PCM",f"{pct}%"], capture_output=True)
    _write(pct, False)
    return pct

def _write(pct, muted):
    tmp = VOL_FILE+".tmp"
    open(tmp,"w").write(json.dumps({"volume":pct,"muted":muted,"ts":time.time()}))
    os.replace(tmp, VOL_FILE)

def mute_toggle(bus):
    r = bus.read_byte_data(TAS_ADDR, TAS_VOL)
    if r < TAS_MIN:
        bus.write_byte_data(TAS_ADDR, TAS_VOL, TAS_MIN)
        subprocess.run(["amixer","set","PCM","0%"], capture_output=True)
        _write(0, True); print("Muted", flush=True)
    else:
        print(f"Unmuted -> {set_vol(bus, DEFAULT)}%", flush=True)

def main():
    dev = evdev.InputDevice(DEVICE); dev.grab()
    bus = smbus2.SMBus(1)
    # Sync ALSA PCM to match TAS5806 at startup so both controls are aligned
    current_pct = get_vol(bus)
    subprocess.run(["amixer", "set", "PCM", f"{current_pct}%"], capture_output=True)
    _write(current_pct, False)
    print(f"Started, vol={current_pct}% (TAS5806+PCM synced)", flush=True)
    signal.signal(signal.SIGTERM, lambda *_: (dev.ungrab(), bus.close(), sys.exit(0)))
    for ev in dev.read_loop():
        if ev.type != evdev.ecodes.EV_KEY or ev.value != 1: continue
        if   ev.code == evdev.ecodes.KEY_VOLUMEUP:   print(f"Vol up   -> {set_vol(bus, get_vol(bus)+STEP)}%", flush=True)
        elif ev.code == evdev.ecodes.KEY_VOLUMEDOWN: print(f"Vol down -> {set_vol(bus, get_vol(bus)-STEP)}%", flush=True)
        elif ev.code == evdev.ecodes.KEY_MICMUTE:    mute_toggle(bus)
        elif ev.code == evdev.ecodes.KEY_VOICECOMMAND: print("Action button", flush=True)

if __name__ == "__main__": main()
