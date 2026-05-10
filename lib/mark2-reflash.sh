#!/bin/bash
# mark2-reflash.sh — DEPRECATED
#
# This script was the old approach to XVF3510 initialization.
# It is no longer used.
#
# SUPERSEDED BY: lib/mark2-xvf-post-wp.sh + mark2-audio-init.service
#
# Root cause found (May 2026): XVF3510 requires MCLK=12.288MHz.
# sj201.dtbo wrongly sets MCLK=24.576MHz.
# Fix: setup_mclk + setup_bclk before SPI flash.
# See docs/XVF3510_HARDWARE.md for full details.
#
# This file is kept for historical reference only.
echo "mark2-reflash.sh is deprecated. Use mark2-audio-init.service instead."
echo "See docs/XVF3510_HARDWARE.md"
