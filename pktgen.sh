#!/usr/bin/env bash
#
# pktgen.sh — In-Kernel UDP-Lasttest ueber mehrere CPU-Kerne.
#
# Ersatz fuer  hping3 -2 <dst> --flood -d <payload>  wenn hping3 nicht ueber
# ~4 Kerne skaliert. pktgen laeuft per-CPU im Kernel und verteilt mit dem Flag
# QUEUE_MAP_CPU jeden Thread auf eine eigene TX-Queue (mit `mq`-qdisc),
# umgeht so den qdisc-Lock und skaliert ueber alle HW-Queues.
#
# Aufruf:
#   pktgen.sh [optionen] <dst-ip>
#
# Optionen:
#   -s, --size <bytes>   Frame-Groesse inkl. Eth-Header (default 1400)
#   -t, --time <sek>     max. Laufzeit (default 60, 0 = bis Strg-C)
#   -n, --threads <n>    Anzahl paralleler hping/pktgen-Threads (default 1)
#   -p, --pps <n>        Pakete/s GESAMT begrenzen (0 = Flood/unbegrenzt, default 0)
#                        Bandbreite = pps * size * 8. Wird auf die Threads aufgeteilt.
#   -r, --rand-source    zufaellige Quell-IPs (SRC_MIN..SRC_MAX) statt fixer Egress-IP
#   -h, --help           Hilfe
#
# Beispiele:
#   pktgen.sh 88.198.41.0                       # IPv4, 1400B, 60s, Flood
#   pktgen.sh -s 1400 -t 120 -n 4 88.198.41.0
#   pktgen.sh -s 1400 -p 100000 88.198.41.0     # 100k pps * 1400B ~= 1.12 Gbit/s
#   pktgen.sh --rand-source 88.198.41.0         # rand-source nur IPv4
#   pktgen.sh 2a01:4f8::1                       # IPv6 (Familie autom. erkannt)
#
# WICHTIG:
#  * Nur gegen eigene, autorisierte Infrastruktur einsetzen (erzeugt echte Last).
#  * pkt_size ist die GESAMTE Frame-Groesse inkl. Ethernet-Header (min 60).
#    2450 UDP-Payload  ~=  pkt_size 2492 (Eth14 + IP20 + UDP8 + 2450) -> Jumbo-MTU noetig!
#    Ohne Jumbo-Frames pkt_size auf 1514 setzen.
#
set -euo pipefail

PGCTRL=/proc/net/pktgen/pgctrl
PGDIR=/proc/net/pktgen

usage() {
    sed -n '10,27p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

##### Argumente ###############################################################

# Defaults (Optionen)
PKT_SIZE=1400
DURATION=60
THREADS=1
PPS=0
RAND_SRC="${RAND_SRC:-0}"
DST=""

while (( $# )); do
    case "$1" in
        -s|--size)        PKT_SIZE="${2:-}"; shift 2 ;;
        -t|--time)        DURATION="${2:-}"; shift 2 ;;
        -n|--threads)     THREADS="${2:-}";  shift 2 ;;
        -p|--pps)         PPS="${2:-}";      shift 2 ;;
        -r|--rand-source) RAND_SRC=1;        shift ;;
        -h|--help)        usage 0 ;;
        --)               shift; break ;;
        -*)               echo "FEHLER: unbekannte Option '$1'" >&2; usage ;;
        *)                if [[ -z "$DST" ]]; then DST="$1"; else echo "FEHLER: zu viele Argumente ('$1')" >&2; usage; fi; shift ;;
    esac
done
[[ -z "${1:-}" ]] || DST="${DST:-$1}"   # ggf. dst nach '--'

[[ -n "$DST" ]] || { echo "FEHLER: <dst-ip> fehlt." >&2; usage; }

# Performance-Schalter (Env):
#   CLONE_SKB : skb-Wiederverwendung. 0 = jedes Paket neu (langsam, aber per-Paket
#               Random-Source moeglich). Gross (z.B. 100000) = Max-pps, aber
#               IPSRC_RND variiert dann nur noch alle CLONE_SKB Pakete.
#   BURST     : xmit_more-Bursts -> weniger Overhead pro Paket. 0 = aus (default 64).
CLONE_SKB="${CLONE_SKB:-100000}"
BURST="${BURST:-64}"

# Quell-IP-Range fuer --rand-source (Env): default 0/0. Fuer uRPF-gueltiges Random
# auf dein eigenes, ueber den Link geroutetes Netz setzen.
SRC_MIN="${SRC_MIN:-0.0.0.1}"
SRC_MAX="${SRC_MAX:-255.255.255.254}"

# Adressfamilie aus dem Ziel ableiten (':' -> IPv6)
if [[ "$DST" == *:* ]]; then
    FAMILY=6
elif [[ "$DST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    FAMILY=4
else
    echo "FEHLER: dst-ip ungueltig: '$DST'" >&2; usage
fi
if (( FAMILY == 6 && RAND_SRC == 1 )); then
    echo "WARNUNG: --rand-source wird fuer IPv6 nicht unterstuetzt; nutze feste Quell-IP." >&2
    RAND_SRC=0
fi

[[ "$DURATION" =~ ^[0-9]+$ ]]                    || { echo "FEHLER: --time muss Zahl sein." >&2; usage; }
[[ "$THREADS"  =~ ^[1-9][0-9]*$ ]]               || { echo "FEHLER: --threads > 0." >&2; usage; }
[[ "$PKT_SIZE" =~ ^[0-9]+$ ]] && (( PKT_SIZE >= 60 )) || { echo "FEHLER: --size >= 60." >&2; usage; }
[[ "$PPS" =~ ^[0-9]+$ ]]                          || { echo "FEHLER: --pps muss Zahl sein (0 = Flood)." >&2; usage; }
[[ "$CLONE_SKB" =~ ^[0-9]+$ ]] || { echo "FEHLER: CLONE_SKB muss Zahl sein." >&2; exit 1; }
[[ "$BURST"     =~ ^[0-9]+$ ]] || { echo "FEHLER: BURST muss Zahl sein." >&2; exit 1; }

##### Checks ##################################################################

[[ $EUID -eq 0 ]] || { echo "FEHLER: pktgen braucht root." >&2; exit 1; }
modprobe pktgen 2>/dev/null || true
[[ -e "$PGCTRL" ]] || { echo "FEHLER: pktgen-Modul nicht geladen (/proc/net/pktgen fehlt)." >&2; exit 1; }

NCPU=$(nproc)
(( THREADS > NCPU )) && { echo "WARNUNG: $THREADS Threads > $NCPU CPU-Kerne; reduziere auf $NCPU." >&2; THREADS=$NCPU; }

# pps ggf. auf die Threads aufteilen (ratep gilt pro Device)
PPS_PER=0
if (( PPS > 0 )); then
    PPS_PER=$(( PPS / THREADS ))
    (( PPS_PER > 0 )) || { echo "FEHLER: --pps ($PPS) kleiner als Threadzahl ($THREADS)." >&2; exit 1; }
    ACTUAL_PPS=$(( PPS_PER * THREADS ))
    (( ACTUAL_PPS != PPS )) && echo "WARNUNG: pps nicht glatt durch $THREADS teilbar -> effektiv $ACTUAL_PPS pps ($PPS_PER/Thread)." >&2
fi

##### Egress-IF, Next-Hop und Ziel-MAC aufloesen ##############################

route_line=$(ip -"$FAMILY" -o route get "$DST") || { echo "FEHLER: keine Route zu $DST." >&2; exit 1; }
IF=$(sed 's/.*dev \([^ ]*\).*/\1/' <<<"$route_line")
NH=$(grep -oP 'via \K[0-9a-fA-F.:]+' <<<"$route_line" || true)
NH="${NH:-$DST}"   # direkt erreichbar -> Ziel selbst
SRC_ADDR="${SRC_ADDR:-$(grep -oP 'src \K[0-9a-fA-F.:]+' <<<"$route_line" || true)}"
[[ -n "$SRC_ADDR" ]] || { echo "FEHLER: Quell-IP nicht ermittelbar; setze SRC_ADDR=..." >&2; exit 1; }

# Neighbor-Eintrag erzwingen (pktgen macht kein ARP/ND)
ping -"$FAMILY" -c1 -W1 "$NH" >/dev/null 2>&1 || true
DSTMAC=$(ip -"$FAMILY" neigh show "$NH" dev "$IF" 2>/dev/null | grep -oiP 'lladdr \K([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1 || true)
[[ -n "$DSTMAC" ]] || {
    echo "FEHLER: konnte Next-Hop-MAC fuer $NH (dev $IF) nicht aufloesen." >&2
    echo "        Manuell pruefen:  ip -$FAMILY neigh show $NH dev $IF" >&2
    exit 1
}

MTU=$(cat "/sys/class/net/$IF/mtu" 2>/dev/null || echo 1500)
(( PKT_SIZE > MTU + 14 )) && echo "WARNUNG: pkt_size $PKT_SIZE > MTU $MTU (+14). Ohne Jumbo-Frames werden Pakete verworfen." >&2

##### Hilfsfunktionen #########################################################

pg_ctl()  { echo "$1" > "$PGCTRL"; }
pg_thr()  { echo "$2" > "$PGDIR/kpktgend_$1"; }
pg_dev()  { echo "$2" > "$PGDIR/$1"; }

DEVICES=()

cleanup() {
    echo
    echo ">>> Stoppe pktgen ..."
    pg_ctl "stop" 2>/dev/null || true
    # Geraete wieder aus den Threads loesen
    for cpu in $(seq 0 $((NCPU - 1))); do
        echo "rem_device_all" > "$PGDIR/kpktgend_$cpu" 2>/dev/null || true
    done
    echo ">>> Ergebnis pro Thread:"
    for d in "${DEVICES[@]:-}"; do
        res=$(grep -E '^Result:' "$PGDIR/$d" 2>/dev/null || true)
        echo "    $d: $res"
    done
}
trap cleanup INT TERM EXIT

##### Konfiguration ###########################################################

echo ">>> pktgen UDP-Flood (IPv$FAMILY) -> $DST  (Next-Hop $NH / $DSTMAC, dev $IF, MTU $MTU)"
if (( RAND_SRC == 1 )); then SRC_INFO="rand $SRC_MIN..$SRC_MAX"; else SRC_INFO="$SRC_ADDR (fix, uRPF-ok)"; fi
echo ">>> Quell-IP: $SRC_INFO"
if (( PPS_PER > 0 )); then
    MBIT=$(( ACTUAL_PPS * PKT_SIZE * 8 / 1000000 ))
    RATE_INFO="$ACTUAL_PPS pps ($PPS_PER/Thread) ~= ${MBIT} Mbit/s (L2)"
else
    RATE_INFO="Flood (unbegrenzt), burst: $BURST"
fi
echo ">>> Rate: $RATE_INFO"
echo ">>> Threads: $THREADS, pkt_size: $PKT_SIZE, clone_skb: $CLONE_SKB, Laufzeit: ${DURATION}s"
echo

# Alle Threads leeren
for cpu in $(seq 0 $((NCPU - 1))); do
    echo "rem_device_all" > "$PGDIR/kpktgend_$cpu"
done

for (( i = 0; i < THREADS; i++ )); do
    cpu=$i
    dev="${IF}@${cpu}"
    DEVICES+=("$dev")

    pg_thr "$cpu" "add_device $dev"

    pg_dev "$dev" "count 0"               # 0 = unendlich (Flood)
    pg_dev "$dev" "flag QUEUE_MAP_CPU"    # -> eigene TX-Queue pro CPU (skaliert!)
    pg_dev "$dev" "clone_skb $CLONE_SKB"  # skb wiederverwenden -> Max-pps
    if (( PPS_PER > 0 )); then
        pg_dev "$dev" "ratep $PPS_PER"    # Pakete/s pro Device begrenzen (kein burst -> gleichmaessig)
    else
        pg_dev "$dev" "delay 0"           # so schnell wie moeglich (Flood)
        (( BURST > 0 )) && pg_dev "$dev" "burst $BURST"   # xmit_more-Batching
    fi
    pg_dev "$dev" "pkt_size $PKT_SIZE"
    pg_dev "$dev" "dst_mac $DSTMAC"
    pg_dev "$dev" "udp_dst_min 9"         # discard-Port; nach Bedarf anpassen
    pg_dev "$dev" "udp_dst_max 9"
    pg_dev "$dev" "udp_src_min 9"
    pg_dev "$dev" "udp_src_max 9"
    if (( FAMILY == 6 )); then
        pg_dev "$dev" "dst6 $DST"
        pg_dev "$dev" "src6 $SRC_ADDR"    # feste, uRPF-gueltige Quell-IP (v6: kein RND)
    else
        pg_dev "$dev" "dst $DST"
        if (( RAND_SRC == 1 )); then
            # zufaellige Quell-IPs (wie hping --rand-source) -> faellt durch Strict-uRPF
            pg_dev "$dev" "flag IPSRC_RND"
            pg_dev "$dev" "src_min $SRC_MIN"
            pg_dev "$dev" "src_max $SRC_MAX"
        else
            # feste, uRPF-gueltige Quell-IP
            pg_dev "$dev" "src_min $SRC_ADDR"
            pg_dev "$dev" "src_max $SRC_ADDR"
        fi
    fi

    echo "[setup ] Thread $i -> $dev"
done

##### Start ###################################################################

echo
echo ">>> Starte Flood ..."
if (( DURATION > 0 )); then
    pg_ctl "start" &          # 'start' blockiert, daher im Hintergrund
    START_PID=$!
    sleep "$DURATION"
    pg_ctl "stop" 2>/dev/null || true
    wait "$START_PID" 2>/dev/null || true
    # cleanup-trap gibt Ergebnis aus
else
    echo ">>> Laeuft bis Strg-C ..."
    pg_ctl "start"
fi
