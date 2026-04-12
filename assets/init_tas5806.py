#!/usr/bin/env python3
# Source: https://github.com/MycroftAI/mark-ii-hardware-testing/blob/main/utils/init_tas5806.py
# Vendored into mark2-assist for reproducibility.
# Retrieved: 2026-04-11

import smbus2
import time

# TAS5806 I2C address
TAS5806_ADDR = 0x2F
I2C_BUS = 1

# Register map
TAS5806_REG_PAGE = 0x00
TAS5806_REG_RESET = 0x01
TAS5806_REG_DEVICE_CTRL_1 = 0x02
TAS5806_REG_DEVICE_CTRL_2 = 0x03
TAS5806_REG_SIG_CH_CTRL = 0x28
TAS5806_REG_SAP_CTRL1 = 0x33
TAS5806_REG_SAP_CTRL2 = 0x34
TAS5806_REG_SAP_CTRL3 = 0x35
TAS5806_REG_FS_MON = 0x37
TAS5806_REG_BCK_MON = 0x38
TAS5806_REG_CLKDET_STATUS = 0x39
TAS5806_REG_VOL_CTL = 0x4C
TAS5806_REG_AGAIN = 0x54
TAS5806_REG_ADR_PIN_CTRL = 0x60
TAS5806_REG_ADR_PIN_CONFIG = 0x61
TAS5806_REG_DSP_MISC = 0x66


def write_reg(bus, reg, val):
    bus.write_byte_data(TAS5806_ADDR, reg, val)
    time.sleep(0.005)


def read_reg(bus, reg):
    return bus.read_byte_data(TAS5806_ADDR, reg)


def init_tas5806():
    try:
        bus = smbus2.SMBus(I2C_BUS)
    except Exception as e:
        print(f"[TAS5806] Could not open I2C bus {I2C_BUS}: {e}")
        return False

    try:
        # Reset device
        write_reg(bus, TAS5806_REG_RESET, 0x11)
        time.sleep(0.01)

        # Set page 0
        write_reg(bus, TAS5806_REG_PAGE, 0x00)

        # Deep sleep -> HIZ
        write_reg(bus, TAS5806_REG_DEVICE_CTRL_2, 0x02)
        time.sleep(0.01)

        # Set SAP format: I2S, 32-bit
        write_reg(bus, TAS5806_REG_SAP_CTRL1, 0x01)

        # Set volume to -13dB (TAS5806: 0x00=0dB, each step=-0.5dB, 0x1a=26*0.5=-13dB)
        # Previous value 0x60 (-48dB) was almost inaudible
        write_reg(bus, TAS5806_REG_VOL_CTL, 0x1a)

        # HIZ -> Play
        write_reg(bus, TAS5806_REG_DEVICE_CTRL_2, 0x03)
        time.sleep(0.01)

        print("[TAS5806] Initialized successfully")
        bus.close()
        return True

    except Exception as e:
        print(f"[TAS5806] Initialization error: {e}")
        bus.close()
        return False


if __name__ == "__main__":
    init_tas5806()
