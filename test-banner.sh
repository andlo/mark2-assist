#!/bin/bash
C=$'\033[0;36m'
B=$'\033[0;34m'
G=$'\033[0;32m'
Y=$'\033[1;33m'
N=$'\033[0m'
echo ""
printf "$C%s$N\n" $'       /\\        '
printf "$C%s$N\n" $'      /  \\        __  __          _     ___ ___ '
printf "$C%s$N\n" $'     /    \\      |  \\/  |__ _ _ _| |__ |_ _|_ _|'
printf "$C%s$N\n" $'    /  /\\  \\     | |\\/| / _` | \'_| / /  | | | | '
printf "$C%s$N\n" $'   /__/  \\__\\    |_|  |_\\__,_|_| |_\\_\\ |___|___|'
printf "$C%s$N\n" $'   |  |  |  |       _          _    _   '
printf "$C%s$N\n" $'   |  |  |  |      /_\\   _____(_)__| |_ '
printf "$C%s$N\n" $'   |  |  |  |     / _ \\ (_-<_-< (_-<  _|'
printf "$C%s$N\n" $'   |__|  |__|    /_/ \\_\\/__/__/_/__/\\__|'
printf "$C%s$N\n" $'                 '
echo ""
printf "$B  Mycroft Mark II — Home Assistant Voice Satellite$N\n"
printf "$B  github.com/andlo/mark2-assist$N\n"
echo ""
printf "  $C——  SSH Login Test  ——$N\n"
echo ""
printf "$G  System:$N\n"
printf "  %-12s %s\n" "Hostname:" "$(hostname)"
printf "  %-12s %s\n" "Uptime:"   "$(uptime -p | sed 's/up //')"
printf "  %-12s %s\n" "IP:"       "$(hostname -I | awk '{print \$1}')"
echo ""
printf "$G  Services:$N\n"
for svc in lva mark2-audio-init wireplumber; do
    st=$(systemctl --user is-active "$svc" 2>/dev/null || echo inactive)
    [ "$st" = "active" ] && printf "  $Gâ$N %-28s %s\n" "$svc" "running" || printf "  $Yâ$N %-28s %s\n" "$svc" "$st"
done
echo ""
