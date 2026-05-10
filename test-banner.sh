#!/bin/bash
C=$'\033[0;36m'
B=$'\033[0;34m'
G=$'\033[0;32m'
N=$'\033[0m'
echo ""
while IFS= read -r line; do
    printf "%s%s%s\n" "$C" "$line" "$N"
done < /tmp/mark2-banner-lines.txt
echo ""
printf "%s  Mycroft Mark II — Home Assistant Voice Satellite%s\n" "$B" "$N"
printf "%s  github.com/andlo/mark2-assist%s\n" "$B" "$N"
echo ""
printf "  %s——  Installer  ——%s\n" "$C" "$N"
echo ""
printf "%s  System:%s\n" "$G" "$N"
printf "  %-12s %s\n" "Hostname:" "$(hostname)"
printf "  %-12s %s\n" "IP:" "$(hostname -I | awk '{print $1}')"
echo ""
