#!/usr/bin/env bash
# runner.sh - lanza y mantiene un pod de RunPod con GPU por alumno.
#
#   ./runner.sh --keyfile keys.txt      lanza un pod por cada clave pública del fichero
#   ./runner.sh status [correo]         estado de todos los pods del curso (o de uno)
#   ./runner.sh reboot <correo>         reinicia el pod en la misma máquina
#   ./runner.sh reset  <correo>         borra el pod y crea uno nuevo con la misma clave
#   ./runner.sh stop   <correo>         para el pod (deja de cobrar la GPU)
#   ./runner.sh start  <correo>         arranca un pod parado
#   ./runner.sh delete <correo>|--all   borra el pod definitivamente
#
# keys.txt: una clave pública por línea, con el correo como comentario:
#   ssh-ed25519 AAAAC3... alumno@example.com
#
# OJO: los pods no tienen disco persistente. reboot, stop y reset dejan el pod
# como recién creado (se pierde lo instalado) y cambian el puerto SSH; por eso
# reboot, start y reset imprimen el comando ssh nuevo.
#
# Necesita: RUNPOD_API_KEY en el entorno, curl y python3.
set -euo pipefail

API="${RUNPOD_API:-https://api.runpod.io/v2}"
IMAGE="${IMAGE:-runpod/base:1.0.2-ubuntu2404}"
DISK_GB="${DISK_GB:-60}"            # disco local del pod
MIN_VRAM="${MIN_VRAM:-16}"          # GB de VRAM mínimos
MAX_PRICE="${MAX_PRICE:-0.80}"      # $/hora máximos por pod
CLOUD="${CLOUD:-SECURE}"            # SECURE garantiza IP pública para el SSH directo
PORTS='["22/tcp","8080/http","5678/http"]'
SSH_WAIT="${SSH_WAIT:-240}"         # segundos de espera a que el pod publique su SSH
NAME_PREFIX="curso-"

log() { echo "$@" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --- API -------------------------------------------------------------------

# api METHOD PATH [BODY] -> escribe el cuerpo en stdout y deja el código HTTP en $HTTP
api() {
  local method=$1 path=$2 body=${3:-} out
  local args=(-sS -X "$method" -H "Authorization: Bearer $RUNPOD_API_KEY" -w $'\n%{http_code}')
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
  out=$(curl "${args[@]}" "$API$path") || die "no se pudo conectar con la API de RunPod"
  HTTP=${out##*$'\n'}
  BODY=${out%$'\n'*}
}

# json 'expresión python sobre d' <<< "$JSON"
json() { python3 -c 'import sys,json; d=json.load(sys.stdin); print('"$1"')'; }

# Todos los pods de la cuenta, uno por línea: correo<TAB>id<TAB>estado<TAB>gpu<TAB>$/h<TAB>host<TAB>puerto
list_pods() {
  local cursor="" all="[]"
  while :; do
    api GET "/pods?limit=200${cursor:+&cursor=$cursor}"
    [ "$HTTP" = 200 ] || die "no se pudieron listar los pods (HTTP $HTTP): $BODY"
    all=$(python3 -c 'import sys,json; a=json.loads(sys.argv[1]); a+=json.load(sys.stdin).get("pods",[]); print(json.dumps(a))' "$all" <<< "$BODY")
    cursor=$(json '(d.get("pagination") or {}).get("nextCursor") or ""' <<< "$BODY")
    [ -n "$cursor" ] || break
  done
  python3 -c '
import sys, json
for p in json.load(sys.stdin):
    email = (p.get("env") or {}).get("STUDENT_EMAIL")
    if not email:
        continue
    d = (p.get("ssh") or {}).get("direct") or {}
    print("\t".join(str(x) for x in (email, p["id"], p.get("status", "?"), (p.get("gpu") or {}).get("id", "?"),
                                     p.get("cost", "?"), d.get("host", "-"), d.get("port", "-"))))
' <<< "$all"
}

pod_id_for() {
  local email=$1 ids
  ids=$(list_pods | awk -F'\t' -v e="$email" '$1==e {print $2}')
  [ -n "$ids" ] || die "no hay ningún pod para $email"
  [ "$(wc -l <<< "$ids")" = 1 ] || die "hay más de un pod para $email: $(tr '\n' ' ' <<< "$ids")"
  echo "$ids"
}

# GPUs con stock, VRAM suficiente y dentro de precio, de más barata a más cara: id<TAB>precio
candidates() {
  api GET "/catalog/gpus?include=AVAILABILITY&product=POD&cloud=$CLOUD"
  [ "$HTTP" = 200 ] || die "no se pudo leer el catálogo de GPUs (HTTP $HTTP): $BODY"
  python3 -c '
import sys, json
cloud, min_vram, max_price = sys.argv[1].lower(), float(sys.argv[2]), float(sys.argv[3])
rows = []
for g in json.load(sys.stdin).get("gpus", []):
    price = (g.get("price") or {}).get(cloud) or 0
    if (g.get("manufacturer") == "NVIDIA" and g.get(cloud) and g.get("availability", "NONE") != "NONE"
            and g.get("memory", 0) >= min_vram and 0 < price <= max_price):
        rows.append((price, g["id"]))
for price, gid in sorted(rows):
    print(f"{gid}\t{price}")
' "$CLOUD" "$MIN_VRAM" "$MAX_PRICE" <<< "$BODY"
}

# create_pod CORREO CLAVE -> id del pod en stdout
create_pod() {
  local email=$1 key=$2 gpu price body cands
  cands=$(candidates)
  [ -n "$cands" ] || { log "  sin stock: ninguna GPU de >=${MIN_VRAM} GB por <=${MAX_PRICE} \$/h en $CLOUD"; return 1; }
  while IFS=$'\t' read -r gpu price; do
    body=$(python3 -c '
import sys, json
email, key, gpu, image, disk, cloud, ports, prefix, admin = sys.argv[1:10]
name = prefix + "".join(c if c.isalnum() else "-" for c in email.lower())
print(json.dumps({
    "name": name[:60], "image": image, "disk": int(disk), "cloud": cloud,
    "gpu": {"id": gpu, "count": 1}, "ports": json.loads(ports),
    "env": {"PUBLIC_KEY": "\n".join(k for k in (key, admin) if k), "STUDENT_EMAIL": email,
            "OLLAMA_CONTEXT_LENGTH": "16384"},
}))' "$email" "$key" "$gpu" "$IMAGE" "$DISK_GB" "$CLOUD" "$PORTS" "$NAME_PREFIX" "$ADMIN_KEY")
    api POST /pods "$body"
    if [ "$HTTP" = 200 ] || [ "$HTTP" = 201 ]; then
      log "  creado en $gpu a $price \$/h"
      json 'd["id"]' <<< "$BODY"
      return 0
    fi
    log "  $gpu no disponible (HTTP $HTTP), pruebo la siguiente"
  done <<< "$cands"
  log "  no se pudo crear el pod: ninguna GPU candidata tenía stock"
  return 1
}

# ssh_line CORREO ID CLAVE -> espera a que el SSH directo responda e imprime "correo ssh root@host -p puerto -i clave"
ssh_line() {
  local email=$1 id=$2 key=$3 host port deadline=$((SECONDS + SSH_WAIT)) keyfile
  case ${key%% *} in
    ssh-rsa) keyfile="~/.ssh/id_rsa" ;;
    ecdsa-*) keyfile="~/.ssh/id_ecdsa" ;;
    *) keyfile="~/.ssh/id_ed25519" ;;
  esac
  while :; do
    api GET "/pods/$id"
    if [ "$HTTP" = 200 ]; then
      host=$(json '((d.get("ssh") or {}).get("direct") or {}).get("host") or ""' <<< "$BODY")
      port=$(json '((d.get("ssh") or {}).get("direct") or {}).get("port") or ""' <<< "$BODY")
      # la API puede devolver unos segundos el puerto anterior: solo vale si responde
      if [ -n "$host" ] && timeout 4 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        echo "$email ssh root@$host -p $port -i $keyfile"
        return 0
      fi
    fi
    [ $SECONDS -lt $deadline ] || break
    sleep 5
  done
  echo "$email SIN-SSH (pod $id: sin puerto SSH tras ${SSH_WAIT}s; prueba './runner.sh status $email')"
  return 1
}

# --- órdenes ---------------------------------------------------------------

cmd_launch() {
  local keyfile=$1 line key email n=0 failed=0
  [ -r "$keyfile" ] || die "no puedo leer $keyfile"
  local existing; existing=$(list_pods)
  local -a emails=() ids=() keys=()
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ -z "${line// }" || "$line" == \#* ]] && continue
    n=$((n + 1))
    key=$(awk '{print $1" "$2}' <<< "$line")
    email=$(awk '{for (i = 3; i <= NF; i++) if ($i ~ /@/) {print $i; exit}}' <<< "$line")
    if [[ ! "$key" =~ ^(ssh-|ecdsa-|sk-)[^\ ]+\ AAAA ]] || [ -z "$email" ]; then
      log "línea $n ignorada: se espera '<tipo> <clave> <correo>'"; failed=$((failed + 1)); continue
    fi
    if printf '%s\n' "${emails[@]:-}" | grep -qxF "$email"; then
      log "línea $n ignorada: $email está repetido"; failed=$((failed + 1)); continue
    fi
    local id; id=$(awk -F'\t' -v e="$email" '$1==e {print $2; exit}' <<< "$existing")
    if [ -n "$id" ]; then
      log "$email: ya tiene el pod $id, no creo otro"
    else
      log "$email: creando pod..."
      id=$(create_pod "$email" "$key $email") || { failed=$((failed + 1)); echo "$email SIN-POD"; continue; }
    fi
    emails+=("$email"); ids+=("$id"); keys+=("$key")
  done < "$keyfile"
  [ $n -gt 0 ] || die "$keyfile no contiene ninguna clave"

  log "Esperando a que los pods publiquen su SSH..."
  local i
  for i in "${!emails[@]}"; do
    ssh_line "${emails[$i]}" "${ids[$i]}" "${keys[$i]}" || failed=$((failed + 1))
  done
  [ $failed -eq 0 ] || { log "$failed clave(s) sin pod utilizable; vuelve a ejecutar la misma orden para reintentar solo esas."; return 1; }
}

cmd_status() {
  local rows; rows=$(list_pods)
  [ -n "${1:-}" ] && rows=$(awk -F'\t' -v e="$1" '$1==e' <<< "$rows")
  [ -n "$rows" ] || { log "no hay pods del curso${1:+ para $1}"; return 0; }
  {
    printf 'CORREO\tPOD\tESTADO\tGPU\t$/H\tSSH\n'
    awk -F'\t' 'BEGIN {OFS="\t"} {print $1, $2, $3, $4, $5, ($6=="-" ? "-" : "ssh root@"$6" -p "$7)}' <<< "$rows"
  } | column -t -s $'\t'
  awk -F'\t' '$3=="RUNNING" {s+=$5} END {printf "Coste de los pods en marcha: %.2f $/hora\n", s}' <<< "$rows" >&2
}

cmd_action() {
  local action=$1 email=$2 id key
  id=$(pod_id_for "$email")
  api POST "/pods/$id/action" "{\"action\":\"$action\"}"
  case $HTTP in
    200|204) log "$email: '$action' aplicado al pod $id" ;;
    409) die "$email: el pod $id no admite '$action' en su estado actual (mira './runner.sh status $email')" ;;
    *) die "$email: '$action' falló (HTTP $HTTP): $BODY" ;;
  esac
  [ "$action" = stop ] && return 0
  key=$(json '(d.get("env") or {}).get("PUBLIC_KEY", "")' <<< "$BODY")
  log "Esperando al SSH nuevo (el puerto cambia)..."
  sleep 20   # deja que el contenedor anterior desaparezca antes de sondear
  ssh_line "$email" "$id" "$key"
}

cmd_reset() {
  local email=$1 id key
  id=$(pod_id_for "$email")
  api GET "/pods/$id"
  [ "$HTTP" = 200 ] || die "no se pudo leer el pod $id (HTTP $HTTP)"
  key=$(json '(d.get("env") or {}).get("PUBLIC_KEY", "").split("\n")[0]' <<< "$BODY")
  [ -n "$key" ] || die "el pod $id no tiene PUBLIC_KEY; relánzalo con --keyfile"
  api POST "/pods/$id/action" '{"action":"terminate"}'
  [ "$HTTP" = 204 ] || [ "$HTTP" = 200 ] || die "no se pudo borrar el pod $id (HTTP $HTTP): $BODY"
  log "$email: pod $id borrado, creando uno limpio..."
  id=$(create_pod "$email" "$key") || die "$email se ha quedado sin pod: vuelve a lanzarlo con --keyfile"
  ssh_line "$email" "$id" "$key"
}

cmd_delete() {
  local target=$1 rows email id
  rows=$(list_pods)
  [ "$target" = "--all" ] || rows=$(awk -F'\t' -v e="$target" '$1==e' <<< "$rows")
  [ -n "$rows" ] || { log "no hay pods que borrar"; return 0; }
  if [ "$target" = "--all" ] && [ "${YES:-}" != 1 ]; then
    log "Se van a borrar $(wc -l <<< "$rows") pods:"; cut -f1,2 <<< "$rows" >&2
    read -r -p "Escribe 'borrar' para confirmar: " ok; [ "$ok" = borrar ] || die "cancelado"
  fi
  while IFS=$'\t' read -r email id _; do
    api POST "/pods/$id/action" '{"action":"terminate"}'
    if [ "$HTTP" = 204 ] || [ "$HTTP" = 200 ]; then log "$email: pod $id borrado"; else log "$email: no se pudo borrar $id (HTTP $HTTP)"; fi
  done <<< "$rows"
}

# --- principal -------------------------------------------------------------

ADMIN_KEY=""
ARGS=()
while [ $# -gt 0 ]; do
  case $1 in
    --keyfile) [ $# -ge 2 ] || usage 1; ARGS=(launch "$2"); shift 2 ;;
    --keyfile=*) ARGS=(launch "${1#*=}"); shift ;;
    --admin-key) [ $# -ge 2 ] || usage 1; ADMIN_KEY=$(head -n1 "$2"); shift 2 ;;   # clave del profesor, entra en todos los pods
    --yes|-y) YES=1; shift ;;
    -h|--help) usage 0 ;;
    --status|--reboot|--reset|--stop|--start|--delete) ARGS+=("${1#--}"); shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ ${#ARGS[@]} -gt 0 ] || usage 1
[ -n "${RUNPOD_API_KEY:-}" ] || die "falta RUNPOD_API_KEY (créala en https://console.runpod.io/user/settings y haz: export RUNPOD_API_KEY=...)"
command -v curl >/dev/null && command -v python3 >/dev/null || die "hacen falta curl y python3"

cmd=${ARGS[0]} arg=${ARGS[1]:-}
case $cmd in
  launch) cmd_launch "$arg" ;;
  status) cmd_status "$arg" ;;
  reboot) [ -n "$arg" ] || usage 1; cmd_action restart "$arg" ;;
  stop)   [ -n "$arg" ] || usage 1; cmd_action stop "$arg" ;;
  start)  [ -n "$arg" ] || usage 1; cmd_action start "$arg" ;;
  reset)  [ -n "$arg" ] || usage 1; cmd_reset "$arg" ;;
  delete) [ -n "$arg" ] || usage 1; cmd_delete "$arg" ;;
  *) usage 1 ;;
esac
