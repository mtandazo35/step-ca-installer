#!/usr/bin/env bash
# Actualiza step-cli y step-ca desde el repositorio de Smallstep.
# Antes: respaldo de /etc/step-ca en /root/backups. Si después de actualizar
# la CA no responde, vuelve a la versión anterior del paquete.
set -Eeuo pipefail

export STEPPATH=/etc/step-ca
LOG=/root/step-ca-actualizar.log
RESPALDOS=/root/backups
FECHA="$(date +%Y%m%d-%H%M%S)"

exec > >(tee -a "$LOG") 2>&1

die() { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "ERROR (código $?) en la línea $LINENO. Registro: $LOG" >&2' ERR

[[ $EUID -eq 0 ]] || die "hay que ejecutarlo como root"
[[ -e "$STEPPATH/config/ca.json" ]] || die "no hay CA en $STEPPATH; usar install.sh"

antes_ca="$(dpkg-query -W -f='${Version}' step-ca)"
antes_cli="$(dpkg-query -W -f='${Version}' step-cli)"
echo "Versiones actuales: step-ca $antes_ca, step-cli $antes_cli"

echo "==> Respaldo"
install -d -m 700 "$RESPALDOS"
respaldo="$RESPALDOS/step-ca-pre-actualizar-$FECHA.tar.gz"
tar -czf "$respaldo" -C / etc/step-ca etc/systemd/system/step-ca.service
chmod 600 "$respaldo"
tar -tzf "$respaldo" >/dev/null || die "el respaldo no se puede leer; no se actualiza"
echo "Respaldo: $respaldo"

echo "==> Actualizando paquetes"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --only-upgrade step-cli step-ca

despues_ca="$(dpkg-query -W -f='${Version}' step-ca)"
if [[ "$despues_ca" == "$antes_ca" ]]; then
  echo "step-ca ya estaba en la última versión ($antes_ca)."
fi

echo "==> Reiniciando y comprobando"
systemctl restart step-ca
sleep 3
if step ca health; then
  echo "OK: step-ca $despues_ca, step-cli $(dpkg-query -W -f='${Version}' step-cli)"
  exit 0
fi

echo "La CA no responde con step-ca $despues_ca. Volviendo a $antes_ca." >&2
journalctl -u step-ca -n 40 --no-pager || true
apt-get install -y -q --allow-downgrades "step-ca=$antes_ca" "step-cli=$antes_cli"
systemctl restart step-ca
sleep 3
if step ca health; then
  die "actualización revertida; la CA funciona otra vez con $antes_ca"
fi
die "la CA sigue sin responder tras revertir. Restaurar con: tar -xzf $respaldo -C / && systemctl restart step-ca"
