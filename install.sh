#!/usr/bin/env bash
# step-ca-installer: CA privada (Smallstep step-ca) con ACME para emitir
# certificados a IPs privadas y nombres internos.
#
# Uso (como root, desde /root):
#   bash install.sh int.ejemplo.com      # CA en ca.int.ejemplo.com, firma *.int.ejemplo.com e IPs privadas
#   bash install.sh                      # sin dominio: solo IPs privadas
#   CA_DNS="10.0.0.5" CA_DOMINIOS="*.lan" bash install.sh int.ejemplo.com
#
# No sobrescribe una CA existente: si /etc/step-ca/config/ca.json ya existe, aborta.
set -Eeuo pipefail

# ---------------------------------------------------------------- variables
CA_DOMINIO="${CA_DOMINIO:-${1:-}}"   # dominio interno (int.ejemplo.com): CA en ca.<dominio>, firma *.<dominio>
CA_NOMBRE="${CA_NOMBRE:-CA interna}"
CA_DNS="${CA_DNS:-}"            # IPs/nombres por los que se llega a la CA, separados por coma (defecto: IP principal)
CA_PUERTO="${CA_PUERTO:-443}"
CA_DURACION="${CA_DURACION:-2160h}"   # duración por defecto y máxima de los certificados (2160h = 90 días)
CA_RANGOS="${CA_RANGOS:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10}"   # IPs que la CA puede firmar
CA_DOMINIOS="${CA_DOMINIOS:-}"  # nombres internos que puede firmar, p. ej. "*.lan,*.int.ejemplo.com"

export STEPPATH=/etc/step-ca
LOG=/root/step-ca-install.log
RESPALDOS=/root/backups
FECHA="$(date +%Y%m%d-%H%M%S)"
CA_CREADA=0

exec > >(tee -a "$LOG") 2>&1

info() { printf '\n==> %s\n' "$*"; }

# Si la instalación falla después de crear la CA, se aparta /etc/step-ca
# (no se borra) para que se pueda volver a lanzar el instalador.
limpiar_fallo() {
  trap - ERR
  if [[ "$CA_CREADA" == 1 ]]; then
    systemctl disable --now step-ca >/dev/null 2>&1 || true
    install -d -m 700 "$RESPALDOS"
    mv "$STEPPATH" "$RESPALDOS/step-ca-fallido-$FECHA"
    echo "La CA a medio crear quedó apartada en $RESPALDOS/step-ca-fallido-$FECHA."
    echo "Se puede volver a ejecutar el instalador."
  fi
}

die() {
  echo "ERROR: $*" >&2
  limpiar_fallo
  exit 1
}

on_error() {
  local rc=$? linea=$1
  echo "ERROR (código $rc) en la línea $linea. Registro completo: $LOG" >&2
  limpiar_fallo
  exit "$rc"
}
trap 'on_error $LINENO' ERR

ip_principal() {
  ip -4 route get 192.0.2.1 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

es_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ || "$1" == *:* ]]; }

# Convierte "a, b,c" en un array JSON ["a","b","c"] sin vacíos.
lista_json() {
  jq -cn --arg s "$1" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

# ---------------------------------------------------------------- comprobaciones
info "Comprobaciones previas"
[[ $EUID -eq 0 ]] || die "hay que ejecutarlo como root"
. /etc/os-release
[[ "${ID:-}" == debian || "${ID:-}" == ubuntu || "${ID_LIKE:-}" == *debian* ]] \
  || die "solo Debian/Ubuntu (detectado: ${PRETTY_NAME:-desconocido})"
[[ -e "$STEPPATH/config/ca.json" ]] \
  && die "ya existe una CA en $STEPPATH; no se sobrescribe. Para actualizarla: actualizar.sh"
if ss -Hltn "sport = :$CA_PUERTO" | grep -q .; then
  ss -Hltnp "sport = :$CA_PUERTO" || true
  die "el puerto $CA_PUERTO ya está en uso (CA_PUERTO=<otro> para cambiarlo)"
fi

if [[ -z "$CA_DNS" ]]; then
  CA_DNS="$(ip_principal)"
  [[ -n "$CA_DNS" ]] || die "no se pudo detectar la IP principal; indicar CA_DNS=\"<ip>,<nombre>\""
fi
if [[ -n "$CA_DOMINIO" ]]; then
  CA_DOMINIO="${CA_DOMINIO#\*.}"
  CA_DOMINIO="${CA_DOMINIO%.}"
  [[ "$CA_DOMINIO" == *.* ]] || die "dominio no válido: $CA_DOMINIO (ejemplo: int.ejemplo.com)"
  # La IP va primero: la CA se comprueba a sí misma por IP, así no depende de
  # que el registro DNS ya exista.
  [[ ",$CA_DNS," == *",ca.$CA_DOMINIO,"* ]] || CA_DNS="$CA_DNS,ca.$CA_DOMINIO"
  CA_DOMINIOS="${CA_DOMINIOS:+$CA_DOMINIOS,}*.$CA_DOMINIO"
fi
IFS=',' read -ra NOMBRES_CA <<<"$CA_DNS"
dns_args=()
for n in "${NOMBRES_CA[@]}"; do
  n="${n// /}"
  [[ -n "$n" ]] && dns_args+=(--dns "$n")
done
echo "CA: \"$CA_NOMBRE\" en :$CA_PUERTO para ${CA_DNS}"

# ---------------------------------------------------------------- paquetes
info "Instalando step-cli y step-ca (repositorio oficial de Smallstep)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends curl ca-certificates jq openssl
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg -o /etc/apt/keyrings/smallstep.asc
cat > /etc/apt/sources.list.d/smallstep.sources <<'EOF'
Types: deb
URIs: https://packages.smallstep.com/stable/debian
Suites: debs
Components: main
Signed-By: /etc/apt/keyrings/smallstep.asc
EOF
apt-get update -q
apt-get install -y -q step-cli step-ca
STEP_CA_BIN="$(command -v step-ca)" || die "el paquete step-ca no dejó el binario en el PATH"
step version
step-ca version

# ---------------------------------------------------------------- usuario
info "Usuario de servicio 'step'"
if ! id step >/dev/null 2>&1; then
  useradd --user-group --system --no-create-home --home-dir "$STEPPATH" --shell /bin/false step
fi
install -d -m 700 -o step -g step "$STEPPATH"
CA_CREADA=1

# ---------------------------------------------------------------- CA
info "Creando la CA"
umask 077
openssl rand -base64 32 > "$STEPPATH/password.txt"              # cifra las claves de la CA
openssl rand -base64 32 > "$STEPPATH/provisioner-password.txt"  # cifra la clave del provisioner admin
step ca init --deployment-type standalone --name "$CA_NOMBRE" \
  "${dns_args[@]}" --address ":$CA_PUERTO" --provisioner admin \
  --password-file "$STEPPATH/password.txt" \
  --provisioner-password-file "$STEPPATH/provisioner-password.txt" </dev/null

# Política: solo IPs de CA_RANGOS y nombres de CA_DOMINIOS, más las IPs y
# nombres de la propia CA. Duración: CA_DURACION como defecto y máximo.
# Provisioner ACME "acme" -> https://<ca>/acme/acme/directory
info "Ajustando duración, política y provisioner ACME en ca.json"
ips=()
dns=()
for n in "${NOMBRES_CA[@]}"; do
  n="${n// /}"
  [[ -z "$n" ]] && continue
  if es_ip "$n"; then ips+=("$n"); else dns+=("$n"); fi
done
ips_json="$(lista_json "$CA_RANGOS$(printf ',%s' "${ips[@]}")")"
dns_json="$(lista_json "$CA_DOMINIOS$(printf ',%s' "${dns[@]}")")"

jq --arg dur "$CA_DURACION" --argjson ips "$ips_json" --argjson dns "$dns_json" '
  .authority.claims = ((.authority.claims // {}) + {defaultTLSCertDuration: $dur, maxTLSCertDuration: $dur})
  | .authority.provisioners |= map(
      if .claims then .claims |= with_entries(select(.key | test("TLSCertDuration$") | not)) else . end)
  | (if ([.authority.provisioners[] | select(.type == "ACME")] | length) == 0
     then .authority.provisioners += [{type: "ACME", name: "acme"}] else . end)
  | .authority.policy = {x509: {allow: ({ip: $ips} + (if ($dns | length) > 0 then {dns: $dns} else {} end))}}
' "$STEPPATH/config/ca.json" > "$STEPPATH/config/ca.json.nuevo"
jq -e '.authority.policy.x509.allow.ip | length > 0' "$STEPPATH/config/ca.json.nuevo" >/dev/null \
  || die "ca.json resultante no válido"
mv "$STEPPATH/config/ca.json.nuevo" "$STEPPATH/config/ca.json"

install -d -m 700 "$STEPPATH/db"
chown -R step:step "$STEPPATH"
chmod 600 "$STEPPATH"/*.txt

# ---------------------------------------------------------------- systemd
info "Servicio systemd (unidad oficial de Smallstep)"
version="$(step-ca version | head -n1 | sed -nE 's#.*/v?([0-9]+\.[0-9]+\.[0-9]+).*#\1#p')"
unidad=/etc/systemd/system/step-ca.service
base=https://raw.githubusercontent.com/smallstep/certificates
if ! curl -fsSL "$base/v$version/systemd/step-ca.service" -o "$unidad" 2>/dev/null; then
  echo "No hay unidad para v$version; se usa la de master."
  curl -fsSL "$base/master/systemd/step-ca.service" -o "$unidad"
fi
grep -q '^ExecStart=' "$unidad" || die "la unidad descargada no es válida"
chmod 644 "$unidad"
if [[ "$STEP_CA_BIN" != /usr/bin/step-ca ]]; then
  sed -i "s#/usr/bin/step-ca#$STEP_CA_BIN#" "$unidad"
fi
systemctl daemon-reload
systemctl enable --now step-ca

info "Comprobando que la CA responde"
for _ in $(seq 1 30); do
  ss -Hltn "sport = :$CA_PUERTO" | grep -q . && break
  sleep 1
done
if ! step ca health; then
  journalctl -u step-ca -n 40 --no-pager || true
  die "step-ca no responde"
fi

# ---------------------------------------------------------------- respaldo
info "Respaldo inicial"
install -d -m 700 "$RESPALDOS"
tar -czf "$RESPALDOS/step-ca-inicial-$FECHA.tar.gz" -C / etc/step-ca
chmod 600 "$RESPALDOS/step-ca-inicial-$FECHA.tar.gz"
CA_CREADA=0   # a partir de aquí la CA es válida: un fallo ya no la aparta

# ---------------------------------------------------------------- resumen
huella="$(step certificate fingerprint "$STEPPATH/certs/root_ca.crt")"
url="https://${NOMBRES_CA[0]// /}"
[[ "$CA_PUERTO" != 443 ]] && url="$url:$CA_PUERTO"

aviso_dns=""
if [[ -n "$CA_DOMINIO" ]]; then
  aviso_dns=" 3. Crear en el DNS del dominio (Cloudflare, cPanel o DirectAdmin; en Cloudflare
    con \"Solo DNS\", nube gris). Ver \"Dominio y registros DNS\" en el README:
      ca.$CA_DOMINIO        A   ${ips[0]:-<IP privada de la CA>}
      <equipo>.$CA_DOMINIO  A   <IP privada del equipo>"
fi

cat <<EOF

=====================================================================
 step-ca instalada
=====================================================================
 URL de la CA ........ $url
 Huella de la raíz ... $huella
 Directorio ACME ..... $url/acme/acme/directory
 Raíz (para clientes)  $STEPPATH/certs/root_ca.crt
 Puede firmar IPs .... $(jq -r 'join(", ")' <<<"$ips_json")
 Puede firmar nombres  $(jq -r 'if length > 0 then join(", ") else "(ninguno)" end' <<<"$dns_json")
 Duración ............ $CA_DURACION
 Registro ............ $LOG

 HACER AHORA:
 1. Copiar FUERA del servidor $RESPALDOS/step-ca-inicial-$FECHA.tar.gz
    (lleva la clave raíz y las contraseñas) y después quitar la raíz de aquí:
      shred -u $STEPPATH/secrets/root_ca_key
 2. Limitar el puerto $CA_PUERTO a las redes internas en el firewall.
${aviso_dns}

 Cliente Linux (confiar en la CA):
   step ca bootstrap --ca-url $url --fingerprint $huella --install

 Certificado a mano para una IP (en este servidor):
   step ca certificate 10.0.0.10 srv.crt srv.key --san 10.0.0.10 \\
     --provisioner admin --provisioner-password-file $STEPPATH/provisioner-password.txt

 Certificado por ACME desde el servidor que lo usará (puerto 80 libre):
   acme.sh --issue --standalone -d 10.0.0.10 --server $url/acme/acme/directory \\
     --ca-bundle /ruta/root_ca.crt
=====================================================================
EOF
