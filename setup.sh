#!/usr/bin/env bash
# setup.sh: instalación guiada de step-ca.
# Explica cada paso, pide los datos, instala (install.sh) y acompaña lo que
# queda después: respaldo, firewall, registros DNS, clientes y el primer
# certificado. Si la CA ya existe, abre un menú con esas mismas tareas.
#
# Uso (como root, desde /root):
#   curl -fsSLO https://raw.githubusercontent.com/mtandazo35/step-ca-installer/main/setup.sh
#   bash setup.sh
set -Eeuo pipefail

REPO_RAW=https://raw.githubusercontent.com/mtandazo35/step-ca-installer/main
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export STEPPATH=/etc/step-ca
TTY=/dev/tty
CERTS=/root/certificados

# ---------------------------------------------------------------- utilidades
negrita() { printf '\033[1m%s\033[0m\n' "$*"; }
titulo() { printf '\n\033[1;36m━━━ %s ━━━\033[0m\n\n' "$*"; }
ok()     { printf '\033[32m✔ %s\033[0m\n' "$*"; }
aviso()  { printf '\033[33m! %s\033[0m\n' "$*"; }
error()  { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; }

pregunta() {   # pregunta "texto" "defecto" -> respuesta por stdout
  local r
  if [[ -n "${2:-}" ]]; then read -rp "$1 [$2]: " r <"$TTY"; echo "${r:-$2}"
  else read -rp "$1: " r <"$TTY"; echo "$r"; fi
}
si_no() {      # si_no "texto" [s|n] -> 0 si responde sí
  local def="${2:-n}" r
  read -rp "$1 [$([[ $def == s ]] && echo S/n || echo s/N)]: " r <"$TTY"
  r="${r:-$def}"
  [[ "$r" =~ ^[sS] ]]
}
pausa() { read -rp "Pulse Enter para continuar..." _ <"$TTY"; }

ip_principal() {
  ip -4 route get 192.0.2.1 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

asegurar_dig() {
  command -v dig >/dev/null && return
  echo "Instalando dig (bind9-dnsutils) para comprobar el DNS..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q bind9-dnsutils >/dev/null 2>&1 ||
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q dnsutils >/dev/null
}

# Datos de la CA ya instalada (de ca.json y defaults.json).
leer_ca() {
  CA_URL="$(jq -r '."ca-url"' "$STEPPATH/config/defaults.json")"
  CA_HUELLA="$(step certificate fingerprint "$STEPPATH/certs/root_ca.crt")"
  CA_NOMBRES="$(jq -r '.dnsNames | join(", ")' "$STEPPATH/config/ca.json")"
  CA_IP="$(jq -r '[.dnsNames[] | select(test("^[0-9.]+$"))][0] // empty' "$STEPPATH/config/ca.json")"
  CA_DOMINIO="$(jq -r '[.dnsNames[] | select(startswith("ca."))][0] // empty | sub("^ca\\."; "")' \
    "$STEPPATH/config/ca.json")"
  CA_PERMITIDO_IP="$(jq -r '.authority.policy.x509.allow.ip // [] | join(", ")' "$STEPPATH/config/ca.json")"
  CA_PERMITIDO_DNS="$(jq -r '.authority.policy.x509.allow.dns // [] | join(", ")' "$STEPPATH/config/ca.json")"
}

# ---------------------------------------------------------------- comprobaciones
[[ -r "$TTY" ]] || { echo "setup.sh es interactivo: ejecútelo en una terminal (bash setup.sh)."; exit 1; }
[[ $EUID -eq 0 ]] || { error "Hay que ejecutarlo como root."; exit 1; }

# ================================================================ pasos posteriores
paso_respaldo() {
  titulo "Respaldo y clave raíz"
  local resp
  resp="$(ls -1t /root/backups/step-ca-inicial-*.tar.gz 2>/dev/null | head -n1 || true)"
  cat <<EOF
La CA tiene dos claves:

  • La RAÍZ (secrets/root_ca_key): es la identidad de la CA. Todos los equipos
    confían en ella. Solo hace falta para rehacer la intermedia, casi nunca.
  • La INTERMEDIA (secrets/intermediate_ca_key): firma los certificados del día
    a día. step-ca la usa continuamente.

Smallstep recomienda guardar la raíz FUERA del servidor. Si alguien la roba,
puede firmar certificados que todos sus equipos aceptarán. Si se pierde, hay
que reinstalar una raíz nueva en todos los equipos.

El instalador dejó un respaldo completo (raíz, intermedia y contraseñas) en:
  ${resp:-/root/backups/step-ca-inicial-<fecha>.tar.gz}

Cópielo a un lugar seguro FUERA de este servidor. Desde su PC, por ejemplo:
  scp root@${CA_IP:-<IP de la CA>}:${resp:-/root/backups/step-ca-inicial-<fecha>.tar.gz} .

EOF
  if [[ ! -e "$STEPPATH/secrets/root_ca_key" ]]; then
    ok "La clave raíz ya no está en este servidor."
    return
  fi
  if si_no "¿Ya copió el respaldo fuera del servidor y comprobó que se abre?"; then
    if si_no "¿Borrar ahora la clave raíz de este servidor (shred)? La CA sigue funcionando."; then
      shred -u "$STEPPATH/secrets/root_ca_key"
      ok "Clave raíz borrada. Solo queda en su respaldo."
    fi
  else
    aviso "Pendiente: copiar el respaldo y luego borrar la raíz con:"
    echo "  shred -u $STEPPATH/secrets/root_ca_key"
    echo "  (o vuelva a ejecutar bash setup.sh y elija 'Respaldo y clave raíz')"
  fi
}

paso_firewall() {
  titulo "Firewall"
  local puerto
  puerto="$(jq -r '.address' "$STEPPATH/config/ca.json" | sed 's/.*://')"
  cat <<EOF
La CA escucha en el puerto $puerto/tcp. Solo los equipos de la red interna
tienen que poder llegar a él: la CA no debe estar abierta a internet.

Además, para validar certificados por ACME, la CA tiene que poder SALIR al
puerto 80 de los equipos que piden el certificado.

Este instalador no modifica el firewall: la decisión es suya.
EOF
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo
    echo "UFW está activo. Para abrir el puerto solo a las redes privadas:"
    echo "  ufw allow from 10.0.0.0/8     to any port $puerto proto tcp"
    echo "  ufw allow from 172.16.0.0/12  to any port $puerto proto tcp"
    echo "  ufw allow from 192.168.0.0/16 to any port $puerto proto tcp"
    echo "  ufw allow from 100.64.0.0/10  to any port $puerto proto tcp"
  else
    echo
    echo "Si usa iptables/nftables o el firewall del hipervisor o del router, permita"
    echo "el puerto $puerto/tcp solo desde sus redes internas."
  fi
  echo
  pausa
}

# Primera zona con NS hacia arriba: nas.int.ejemplo.com -> ejemplo.com
zona_de() {
  local d="$1"
  while [[ "$d" == *.* ]]; do
    if [[ -n "$(dig +short +time=3 +tries=1 NS "$d" @1.1.1.1 2>/dev/null)" ]]; then
      echo "$d"; return
    fi
    d="${d#*.}"
  done
}

instrucciones_panel() {   # panel nombre_completo relativo zona ip
  local panel="$1" fqdn="$2" rel="$3" zona="$4" ip="$5"
  case "$panel" in
    cloudflare) cat <<EOF
CLOUDFLARE
  1. Entre en https://dash.cloudflare.com y elija el dominio $zona.
  2. Menú DNS → Records → botón "Add record".
  3. Type: A
     Name: $rel
     IPv4 address: $ip
  4. Proxy status: DESACTIVADO ("DNS only", nube GRIS).
     Es obligatorio: el proxy de Cloudflare (nube naranja) no puede llegar a una
     IP privada y el nombre dejaría de funcionar.
  5. TTL: Auto → "Save".
EOF
    ;;
    cpanel) cat <<EOF
CPANEL
  1. Entre en cPanel con la cuenta que tiene el dominio $zona.
  2. Sección "Dominios" → "Zone Editor" (Editor de zona).
  3. En la fila de $zona pulse "+ A Record"
     (o "Manage" → "+ Add Record" → tipo A).
  4. Name: $rel   (cPanel completa el resto: $fqdn.)
     Address / Record: $ip
     TTL: el que propone (14400).
  5. "Save Record" (Guardar registro).
EOF
    ;;
    directadmin) cat <<EOF
DIRECTADMIN
  1. Entre en DirectAdmin con el usuario dueño del dominio $zona.
  2. "Account Manager" → "DNS Management". Elija $zona si hay varios.
  3. "Add Record":
     Type: A
     Name: $rel   ← relativo, SIN el dominio y SIN punto final.
       (Si lo escribe completo, debe terminar en punto: $fqdn.)
     Value: $ip
     TTL: el que propone.
  4. "Add".
EOF
    ;;
    unbound) cat <<EOF
UNBOUND (solo DNS interno)
  En el servidor Unbound que usan sus equipos, cree o amplíe un archivo, por
  ejemplo /etc/unbound/unbound.conf.d/dominio-interno.conf:

    server:
        local-data: "$fqdn. A $ip"

  y aplique:
    unbound-checkconf && systemctl reload unbound
EOF
    ;;
    adguard) cat <<EOF
ADGUARD HOME / PI-HOLE (solo DNS interno)
  AdGuard Home: "Filtros" → "Reescrituras DNS" → "Añadir reescritura DNS":
     Dominio: $fqdn     Respuesta: $ip
  Pi-hole v6: "Settings" → "Local DNS Records":
     Domain: $fqdn      IP: $ip  → "Add"
EOF
    ;;
    mikrotik) cat <<EOF
MIKROTIK (solo DNS interno, si los equipos usan el router como DNS)
  /ip dns static add name=$fqdn address=$ip
EOF
    ;;
    *) cat <<EOF
OTRO PANEL
  Cree un registro de tipo A:
     Nombre: $fqdn   (o "$rel" si el panel pide el nombre relativo a $zona)
     Valor:  $ip
  Si el panel tiene un proxy o CDN (como Cloudflare), desactívelo para este registro.
EOF
    ;;
  esac
}

comprobar_registro() {   # fqdn ip publico(s/n)
  local fqdn="$1" ip="$2" publico="$3" pub="" loc=""
  while true; do
    echo
    if [[ "$publico" == s ]]; then
      pub="$(dig +short +time=3 +tries=1 A "$fqdn" @1.1.1.1 2>/dev/null | tail -n1 || true)"
    fi
    loc="$(dig +short +time=3 +tries=1 A "$fqdn" 2>/dev/null | tail -n1 || true)"
    [[ "$publico" == s ]] && echo "  DNS público (1.1.1.1) ...... ${pub:-sin respuesta}"
    echo "  DNS de este servidor ....... ${loc:-sin respuesta}"
    if [[ "$loc" == "$ip" && ( "$publico" != s || "$pub" == "$ip" ) ]]; then
      ok "$fqdn resuelve a $ip."
      return 0
    fi
    if [[ "$publico" == s && "$pub" == "$ip" && "$loc" != "$ip" ]]; then
      cat <<EOF

El DNS público ya responde, pero el resolver interno no. Lo más probable es
que tenga PROTECCIÓN CONTRA DNS REBINDING: descarta las respuestas de internet
que apuntan a IPs privadas. Hay que exceptuar el dominio en ese resolver:
  • Unbound .............. private-domain: "${fqdn#*.}"
  • dnsmasq / Pi-hole .... rebind-domain-ok=/${fqdn#*.}/
  • pfSense / OPNsense ... excepción en "DNS Rebinding Checks" (private-domain)
EOF
    elif [[ "$publico" == s && -z "$pub" ]]; then
      echo
      echo "Todavía no aparece en el DNS público. Si lo acaba de crear, puede tardar"
      echo "unos minutos. Compruebe también que lo creó en el panel correcto (NS)."
    fi
    si_no "¿Volver a comprobar?" s || { aviso "Queda pendiente: $fqdn → $ip"; return 1; }
  done
}

paso_dns() {
  titulo "Registros DNS"
  if [[ -z "${CA_DOMINIO:-}" ]]; then
    cat <<EOF
La CA se instaló SIN dominio: solo emite certificados para IPs privadas, y
no hace falta crear ningún registro DNS.

Para usar nombres (https://nas.int.ejemplo.com) hay que reinstalar con un
dominio interno: bash setup.sh (en una CA nueva).
EOF
    pausa; return
  fi
  asegurar_dig
  local fqdn="ca.$CA_DOMINIO" ip="${CA_IP:-}" zona rel ns panel op publico
  cat <<EOF
Para que los equipos lleguen a la CA y a los servicios por nombre, cada nombre
tiene que resolver a su IP privada, en los equipos y también en la propia CA,
porque la CA lo resuelve al validar por ACME.

Se crea un registro de tipo A por cada nombre:
  $fqdn  →  ${ip:-<IP de la CA>}         (la CA, ahora)
  <equipo>.$CA_DOMINIO  →  <IP del equipo>   (luego, uno por cada servicio)

Hay dos formas de publicarlos:
  • En el DNS PÚBLICO del dominio (Cloudflare, cPanel, DirectAdmin…). Funciona
    en cualquier red, pero cualquiera puede ver los nombres y las IPs internas.
  • Solo en el DNS INTERNO (Unbound, AdGuard, Pi-hole, MikroTik). No revela
    nada, pero solo funciona en los equipos que usan ese DNS.

EOF
  [[ -n "$ip" ]] || ip="$(pregunta "IP privada de la CA" "$(ip_principal)")"
  zona="$(zona_de "$CA_DOMINIO" || true)"
  [[ -n "$zona" ]] || zona="$(pregunta "Dominio principal (la zona del panel)" "${CA_DOMINIO#*.}")"
  rel="${fqdn%."$zona"}"
  ns="$(dig +short +time=3 +tries=1 NS "$zona" @1.1.1.1 2>/dev/null | tr '\n' ' ' || true)"

  echo "Zona: $zona"
  echo "Servidores DNS de la zona (NS): ${ns:-no se pudieron consultar}"
  if [[ "$ns" == *cloudflare* ]]; then
    ok "El dominio está en Cloudflare: los registros públicos se crean allí."
  elif [[ -n "$ns" ]]; then
    echo "Los registros públicos se crean en el panel al que apuntan esos NS."
    echo "Si los crea en otro panel, se guardan sin error pero nadie los ve."
  fi
  cat <<EOF

¿Dónde va a crear el registro?
  1) Cloudflare
  2) cPanel
  3) DirectAdmin
  4) Unbound (solo DNS interno)
  5) AdGuard Home / Pi-hole (solo DNS interno)
  6) MikroTik (solo DNS interno)
  7) Otro panel
EOF
  op="$(pregunta "Opción" "$([[ "$ns" == *cloudflare* ]] && echo 1 || echo 2)")"
  case "$op" in
    1) panel=cloudflare publico=s ;;  2) panel=cpanel publico=s ;;
    3) panel=directadmin publico=s ;; 4) panel=unbound publico=n ;;
    5) panel=adguard publico=n ;;     6) panel=mikrotik publico=n ;;
    *) panel=otro; si_no "¿Es el DNS público del dominio?" s && publico=s || publico=n ;;
  esac
  echo
  instrucciones_panel "$panel" "$fqdn" "$rel" "$zona" "$ip"
  echo
  echo "Para cada equipo se repite lo mismo con su nombre e IP, por ejemplo:"
  echo "  ${rel/#ca/nas}  →  10.0.0.10   (nas.$CA_DOMINIO)"
  echo
  read -rp "Cree el registro y pulse Enter para comprobarlo..." _ <"$TTY"
  comprobar_registro "$fqdn" "$ip" "$publico" || true
}

paso_clientes() {
  titulo "Equipos que deben confiar en la CA"
  cat <<EOF
Un certificado de esta CA solo es válido en los equipos que tienen instalada
su RAÍZ. Se instala una sola vez en cada equipo, navegador o programa.

Datos para la instalación:
  URL de la CA ....... $CA_URL
  Huella de la raíz .. $CA_HUELLA
  Archivo de la raíz . $STEPPATH/certs/root_ca.crt

Para copiar la raíz a su PC:
  scp root@${CA_IP:-<IP de la CA>}:$STEPPATH/certs/root_ca.crt .

LINUX con step-cli (descarga la raíz, comprueba la huella y la instala):
  step ca bootstrap --ca-url $CA_URL --fingerprint $CA_HUELLA --install

LINUX sin step-cli (Debian/Ubuntu):
  cp root_ca.crt /usr/local/share/ca-certificates/ca-interna.crt
  update-ca-certificates

WINDOWS (PowerShell o CMD como administrador):
  certutil -addstore -f Root root_ca.crt
  En un dominio de Active Directory se reparte por GPO.

FIREFOX: no usa el almacén del sistema. En about:config ponga
  security.enterprise_roots.enabled = true
  o importe la raíz en Ajustes → Privacidad y seguridad → Certificados.

ANDROID: Ajustes → Seguridad → Cifrado y credenciales → Instalar certificado
  → Certificado de CA. El navegador la acepta; las apps solo si lo declaran.

Antes de instalarla, compruebe que la huella coincide con la de arriba:
  step certificate fingerprint root_ca.crt
EOF
  echo
  pausa
}

paso_certificado() {
  titulo "Emitir un certificado"
  cat <<EOF
Hay dos formas de que un equipo tenga su certificado:

  A) A MANO (ahora, desde aquí). Usted copia el certificado al equipo y lo carga
     en su servicio. Sirve para routers, paneles, appliances, cualquier cosa.
     Hay que volver a emitirlo antes de que venza.

  B) POR ACME (desde el propio equipo, con acme.sh). Se renueva solo. Sirve para
     servidores Linux con el puerto 80 libre o con un servidor web.

Esta CA puede firmar:
  IPs .....  ${CA_PERMITIDO_IP:-(ninguna)}
  Nombres .. ${CA_PERMITIDO_DNS:-(ninguno)}
EOF
  echo
  si_no "¿Emitir ahora un certificado a mano (forma A)?" s || { ayuda_acme; return; }

  local nombre extra dir sans=()
  nombre="$(pregunta "IP o nombre principal del equipo (ej. 10.0.0.10 o nas.${CA_DOMINIO:-int.ejemplo.com})")"
  [[ -n "$nombre" ]] || { aviso "Sin nombre: no se emite nada."; return; }
  extra="$(pregunta "Otros nombres o IPs del mismo equipo, separados por coma (Enter = ninguno)" "")"
  sans=(--san "$nombre")
  IFS=',' read -ra otros <<<"$extra"
  for o in "${otros[@]}"; do o="${o// /}"; [[ -n "$o" ]] && sans+=(--san "$o"); done

  dir="$CERTS/$nombre"
  install -d -m 700 "$dir"
  if step ca certificate "$nombre" "$dir/certificado.crt" "$dir/clave.key" "${sans[@]}" \
      --provisioner admin --provisioner-password-file "$STEPPATH/provisioner-password.txt" \
      --force </dev/null; then
    chmod 600 "$dir/clave.key"
    ok "Certificado emitido."
    cat <<EOF

  Certificado (con la intermedia) .. $dir/certificado.crt
  Clave privada .................... $dir/clave.key
  Válido hasta ..................... $(openssl x509 -enddate -noout -in "$dir/certificado.crt" | cut -d= -f2)

Cópielos al equipo y cárguelos en su servicio. Por ejemplo, en nginx:
  ssl_certificate     /etc/ssl/certs/certificado.crt;
  ssl_certificate_key /etc/ssl/private/clave.key;

Para renovarlo: vuelva a ejecutar bash setup.sh antes de la fecha de arriba y
emita de nuevo. Si el equipo es Linux y tiene step-cli con la raíz instalada,
puede renovarse solo con:
  step ca renew --daemon --exec "systemctl reload nginx" certificado.crt clave.key
EOF
  else
    error "La CA rechazó la petición."
    echo "Si el error menciona 'policy', el nombre o la IP no está entre los permitidos (arriba)."
  fi
  echo
  si_no "¿Ver también cómo hacerlo por ACME (forma B)?" && ayuda_acme
  return 0
}

ayuda_acme() {
  cat <<EOF

FORMA B: ACME con acme.sh, en el equipo que va a usar el certificado
  1. Instalar la raíz de la CA en ese equipo (ver "Equipos que deben confiar").
  2. Instalar acme.sh:   curl https://get.acme.sh | sh
  3. Pedir el certificado (el puerto 80 del equipo tiene que estar libre; si
     ya tiene un servidor web, cambie --standalone por --webroot /var/www/html):
       ~/.acme.sh/acme.sh --issue --standalone -d <IP o nombre del equipo> \\
         --server $CA_URL/acme/acme/directory \\
         --ca-bundle /usr/local/share/ca-certificates/ca-interna.crt
  4. Instalarlo en el servicio (acme.sh lo renovará solo con su cron):
       ~/.acme.sh/acme.sh --install-cert -d <IP o nombre> \\
         --key-file /etc/ssl/private/clave.key \\
         --fullchain-file /etc/ssl/certs/certificado.crt \\
         --reloadcmd "systemctl reload nginx"

  La CA se conecta al puerto 80 del equipo para comprobar que es suyo: el
  firewall tiene que dejar pasar esa conexión.
EOF
  pausa
}

menu() {
  leer_ca
  while true; do
    titulo "step-ca: CA ya instalada"
    echo "  URL: $CA_URL    Nombres: $CA_NOMBRES"
    cat <<EOF

  1) Emitir un certificado
  2) Equipos que deben confiar en la CA (instalar la raíz)
  3) Registros DNS
  4) Respaldo y clave raíz
  5) Firewall
  6) Actualizar step-ca
  0) Salir
EOF
    case "$(pregunta "Opción" 0)" in
      1) paso_certificado ;;
      2) paso_clientes ;;
      3) paso_dns ;;
      4) paso_respaldo ;;
      5) paso_firewall ;;
      6) obtener actualizar.sh && bash "$(ruta actualizar.sh)" || true; pausa ;;
      *) return ;;
    esac
  done
}

ruta() { if [[ -f "$DIR/$1" ]]; then echo "$DIR/$1"; else echo "/root/step-ca-$1"; fi; }
obtener() {   # usa el script del repo si está al lado; si no, lo descarga a /root
  [[ -f "$DIR/$1" ]] && return 0
  curl -fsSL "$REPO_RAW/$1" -o "/root/step-ca-$1"
}

# ================================================================ instalación
instalar() {
  titulo "Instalación guiada de step-ca"
  cat <<EOF
Este asistente instala una AUTORIDAD DE CERTIFICACIÓN (CA) PRIVADA con step-ca.

¿Para qué? Para que sus equipos internos tengan HTTPS con certificado válido:
  https://10.0.0.10   o   https://nas.int.ejemplo.com
Ninguna CA pública (Let's Encrypt incluida) firma certificados para IPs
privadas ni para nombres internos. Una CA propia sí, y sus equipos la aceptan
en cuanto se les instala su certificado raíz.

Qué va a pasar:
  1. Le pediré 4 datos (con valores por defecto).
  2. Se instalan step-ca y step-cli desde el repositorio oficial de Smallstep.
  3. Se crea la CA en /etc/step-ca, como servicio "step-ca" con usuario propio.
  4. La CA queda limitada a firmar IPs privadas y su dominio interno.
  5. Le acompaño con: respaldo, firewall, DNS, equipos y primer certificado.

Requisitos: Debian o Ubuntu, acceso a internet para descargar paquetes, y que
este servidor esté en la red interna (la CA NO debe quedar expuesta a internet).
EOF
  echo
  si_no "¿Continuar?" s || exit 0

  titulo "1/4  IP de la CA"
  cat <<EOF
Es la IP por la que los equipos de la red van a llegar a esta CA. Normalmente
la IP privada de este servidor. Va dentro del certificado de la propia CA.
EOF
  local ip dominio puerto dias
  ip="$(pregunta "IP de la CA" "$(ip_principal)")"

  titulo "2/4  Dominio interno (opcional)"
  cat <<EOF
Si quiere entrar a sus equipos por NOMBRE (https://nas.int.ejemplo.com) y no
solo por IP, indique un SUBDOMINIO de un dominio suyo dedicado a lo interno:
  int.ejemplo.com,  lan.ejemplo.com, ...
  • La CA quedará en ca.<dominio> y podrá firmar <equipo>.<dominio>.
  • Cubre un solo nivel: nas.int.ejemplo.com sí, a.nas.int.ejemplo.com no.
  • Evite .local (choca con mDNS) y dominios inventados (.lan, .corp).
  • Después habrá que crear los registros DNS; se lo explico al final.
Déjelo vacío para usar solo IPs.
EOF
  dominio="$(pregunta "Dominio interno (Enter = sin dominio)" "")"
  dominio="${dominio#\*.}"; dominio="${dominio#ca.}"; dominio="${dominio%.}"

  titulo "3/4  Puerto"
  echo "Puerto HTTPS en el que escuchará la CA. 443 salvo que ya esté ocupado."
  puerto="$(pregunta "Puerto" 443)"

  titulo "4/4  Duración de los certificados"
  cat <<EOF
Cuántos días valen los certificados que emita la CA. Con renovación automática
(ACME) se puede usar poco; para certificados que se copian a mano, 90 días es
un equilibrio entre seguridad y trabajo. Es también el máximo permitido.
EOF
  dias="$(pregunta "Días" 90)"
  [[ "$dias" =~ ^[0-9]+$ && "$dias" -gt 0 ]] || { error "Número de días no válido: $dias"; exit 1; }

  titulo "Resumen"
  cat <<EOF
  IP de la CA ........ $ip
  Dominio interno .... ${dominio:-(ninguno: solo IPs)}
  Nombre de la CA .... ${dominio:+ca.$dominio}
  Puerto ............. $puerto
  Duración ........... $dias días
  Podrá firmar ....... IPs privadas (10/8, 172.16/12, 192.168/16, 100.64/10)${dominio:+ y *.$dominio}
EOF
  echo
  si_no "¿Instalar con estos datos?" s || exit 0

  titulo "Instalando"
  obtener install.sh
  CA_RESUMEN=0 CA_DNS="$ip" CA_PUERTO="$puerto" CA_DURACION="$((dias * 24))h" \
    bash "$(ruta install.sh)" "$dominio" || { error "La instalación falló. Detalle: /root/step-ca-install.log"; exit 1; }
  ok "CA instalada y respondiendo."

  leer_ca
  paso_respaldo
  paso_firewall
  paso_dns
  paso_clientes
  paso_certificado

  titulo "Listo"
  cat <<EOF
  URL de la CA ....... $CA_URL
  Huella de la raíz .. $CA_HUELLA
  Servicio ........... systemctl status step-ca   ·   journalctl -u step-ca
  Registro ........... /root/step-ca-install.log

Vuelva a ejecutar "bash setup.sh" cuando quiera emitir otro certificado,
repasar el DNS o los equipos, o actualizar: con la CA ya instalada abre un menú.
EOF
}

# ================================================================ inicio
if [[ -e "$STEPPATH/config/ca.json" ]]; then
  menu
else
  instalar
fi
