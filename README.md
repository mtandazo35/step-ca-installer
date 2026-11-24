# step-ca-installer

Instala una **CA privada** con [step-ca](https://smallstep.com/docs/step-ca/) (Smallstep) en Debian o
Ubuntu, lista para emitir certificados a **IPs privadas** (`https://10.0.0.10`) y a nombres internos
(`nas.lan`). Ninguna CA pública firma ese tipo de certificados.

La CA emite de dos formas:

- **A mano**, con el provisioner `admin`: `step ca certificate`.
- **Por ACME**, con el provisioner `acme` y renovación automática. Con HTTP-01 valida IPs privadas,
  porque la CA está dentro de la red.

Los clientes confían en los certificados en cuanto se instala la raíz (`root_ca.crt`).

## Instalación

Como root, en `/root`:

```bash
cd /root
curl -fsSLO https://raw.githubusercontent.com/mtandazo35/step-ca-installer/main/install.sh
bash install.sh int.ejemplo.com     # con dominio interno
bash install.sh                     # sin dominio: solo certificados para IPs privadas
```

**El dominio** es un subdominio de un dominio propio, reservado para los equipos internos:
`int.ejemplo.com`. Con él, la CA queda en `ca.int.ejemplo.com` y puede firmar cualquier
`<equipo>.int.ejemplo.com`, además de las IPs privadas. Después hay que crear los registros DNS:
ver [Dominio y registros DNS](#dominio-y-registros-dns).

Variables opcionales:

| Variable | Defecto | Qué es |
|---|---|---|
| `CA_DOMINIO` | primer argumento | dominio interno; equivale a pasarlo como argumento |
| `CA_DNS` | IP principal del servidor | IPs y nombres por los que se llega a la CA, separados por coma |
| `CA_NOMBRE` | `CA interna` | nombre que aparece en la raíz |
| `CA_PUERTO` | `443` | puerto HTTPS de la CA |
| `CA_DURACION` | `2160h` (90 días) | duración por defecto **y máxima** de los certificados |
| `CA_RANGOS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10` | IPs que la CA puede firmar |
| `CA_DOMINIOS` | `*.<dominio>` si hay dominio | otros nombres internos que puede firmar, p. ej. `*.lan` |

```bash
CA_DNS="10.0.0.5" CA_DOMINIOS="*.lan" bash install.sh int.ejemplo.com
```

## Qué hace

1. Comprueba root, Debian/Ubuntu y que el puerto esté libre. **Aborta si ya hay una CA** en
   `/etc/step-ca`, para no sobrescribir nunca una raíz en uso.
2. Instala `step-cli` y `step-ca` desde el repositorio apt oficial de Smallstep (formato deb822,
   clave en `/etc/apt/keyrings/smallstep.asc`).
3. Crea el usuario de sistema `step` y `/etc/step-ca` con permisos `700`.
4. Genera dos contraseñas aleatorias: `password.txt` para las claves de la CA y
   `provisioner-password.txt` para el provisioner `admin`. Después crea la CA con `step ca init`.
5. Modifica `ca.json`:
   - pone `CA_DURACION` como duración por defecto y máxima. La de step-ca es de 24 h;
   - añade el provisioner ACME `acme`, cuyo directorio queda en `https://<ca>/acme/acme/directory`;
   - añade una **política** que permite firmar solo las IPs de `CA_RANGOS` y los nombres de
     `CA_DOMINIOS`, más las IPs y nombres de la propia CA. Cualquier otra petición se rechaza,
     por ejemplo una IP pública o `google.com`.
6. Instala la **unidad systemd oficial** de Smallstep, la de la etiqueta de la versión instalada,
   y arranca el servicio.
7. Comprueba que la CA responde con `step ca health`.
8. Deja un respaldo en `/root/backups/step-ca-inicial-<fecha>.tar.gz`.

Si algo falla después de crear la CA, `/etc/step-ca` se aparta a
`/root/backups/step-ca-fallido-<fecha>` (no se borra) y el instalador se puede volver a lanzar.

## Después de instalar

1. **Copiar el respaldo fuera del servidor** y quitar de él la clave raíz. step-ca no la necesita
   para funcionar, y Smallstep recomienda guardarla offline:
   ```bash
   shred -u /etc/step-ca/secrets/root_ca_key
   ```
   Sin la raíz no se puede rehacer la intermedia sin reinstalar la raíz en todos los clientes. El
   respaldo es la única copia.
2. **Firewall:** el puerto de la CA abierto solo a las redes internas. El instalador no toca el
   firewall. Para validar por ACME, la CA tiene que poder salir al puerto 80 de los servidores a
   certificar.

## Dominio y registros DNS

Solo hace falta si se instaló con dominio. Para que `https://nas.int.ejemplo.com` funcione, el nombre
tiene que resolver a la IP privada del equipo **en los clientes y en la propia CA**: la CA lo
resuelve para validar por ACME.

### Qué dominio usar

- Un **subdominio de un dominio propio**, dedicado a lo interno: `int.ejemplo.com`, `lan.ejemplo.com`.
- El comodín de la política cubre **un solo nivel**: `*.int.ejemplo.com` firma
  `nas.int.ejemplo.com` pero no `a.nas.int.ejemplo.com`.
- No usar `.local`, que choca con mDNS (Bonjour/Avahi), ni dominios inventados como `.lan` o
  `.corp`, que pueden convertirse en dominios públicos reales. Sin dominio propio, la opción
  reservada es `home.arpa` (RFC 8375), y entonces los registros van solo en el DNS interno (ver más
  abajo).

### Registros a crear

En la zona `ejemplo.com`, todos de tipo **A**:

| Nombre (relativo a la zona) | Valor | Para qué |
|---|---|---|
| `ca.int` | IP privada de la CA, p. ej. `10.0.0.5` | la CA |
| `nas.int` | `10.0.0.10` | un registro por cada equipo que lleve certificado |

**Primero, comprobar dónde está el DNS del dominio.** Los registros se crean en el panel que
responde por el dominio, no en el que tiene la web o el correo:

```bash
dig +short NS ejemplo.com
# *.ns.cloudflare.com         -> Cloudflare
# ns1/ns2 del hosting cPanel  -> cPanel
# ns1/ns2 del DirectAdmin     -> DirectAdmin
```

Si se crean en un panel que no es el autoritativo, el panel los guarda sin dar error y nadie los ve.

### Cloudflare

1. Entrar en el panel de Cloudflare y elegir el dominio `ejemplo.com`.
2. Menú **DNS → Records** → **Add record**.
3. **Type:** `A`. **Name:** `ca.int`. **IPv4 address:** `10.0.0.5`.
4. **Proxy status: DNS only** (nube **gris**). Es obligatorio: el proxy de Cloudflare (nube naranja)
   no puede llegar a una IP privada.
5. **TTL:** Auto → **Save**.
6. Repetir con cada equipo (`nas.int` → `10.0.0.10`, …).

### cPanel

1. Entrar en cPanel con la cuenta del dominio.
2. Sección **Dominios → Zone Editor** (Editor de zona).
3. En la fila de `ejemplo.com`, botón **+ A Record**, o **Manage → + Add Record → A**.
4. **Name:** `ca.int`. cPanel completa el resto y lo guarda como `ca.int.ejemplo.com.`.
   **Address/Record:** `10.0.0.5`. **TTL:** el que proponga (14400).
5. **Save Record**. Repetir con cada equipo.

### DirectAdmin

1. Entrar en DirectAdmin con el usuario dueño del dominio.
2. **Account Manager → DNS Management** y elegir `ejemplo.com` si hay varios.
3. **Add Record**. **Type:** `A`. **Name:** `ca.int`, sin el dominio y **sin punto final**: es
   relativo a la zona. Si se escribe completo, tiene que terminar en punto: `ca.int.ejemplo.com.`.
   **Value:** `10.0.0.5`. **TTL:** el que proponga.
4. **Add**. Repetir con cada equipo.

### Comprobar

```bash
dig +short ca.int.ejemplo.com @1.1.1.1     # DNS público: debe dar 10.0.0.5
dig +short ca.int.ejemplo.com              # resolver interno de la red: también 10.0.0.5
```

Si el DNS público responde y el interno no, el resolver interno tiene **protección contra DNS
rebinding**: descarta respuestas públicas que apuntan a IPs privadas. Hay que exceptuar el dominio
interno:

- **Unbound:** `private-domain: "int.ejemplo.com"`, si usa `private-address`.
- **dnsmasq / Pi-hole / OpenWrt:** `rebind-domain-ok=/int.ejemplo.com/`.
- **pfSense / OPNsense:** añadir el dominio en las excepciones de "DNS Rebinding Checks"
  (`private-domain` en Unbound).

### Sin registros públicos (solo DNS interno)

Los registros públicos con IPs privadas revelan los nombres y las IPs internas a cualquiera que
consulte. Si eso no se quiere, los mismos registros se crean **solo en el DNS interno**:

- **Unbound:** `local-data: "ca.int.ejemplo.com. A 10.0.0.5"`.
- **AdGuard Home / Pi-hole:** reescritura DNS o registro local.
- **MikroTik:** `/ip dns static add name=ca.int.ejemplo.com address=10.0.0.5`.

En ese caso los clientes y la CA tienen que usar ese resolver interno. Fuera de la red, o por VPN sin
ese DNS, los nombres no resuelven.

## Clientes: confiar en la raíz

```bash
# Linux con step-cli (comprueba la huella e instala la raíz en el sistema)
step ca bootstrap --ca-url https://10.0.0.5 --fingerprint <HUELLA> --install
# Linux sin step-cli
cp root_ca.crt /usr/local/share/ca-certificates/ca-interna.crt && update-ca-certificates
```

- **Windows:** `certutil -addstore -f Root root_ca.crt`, o por GPO.
- **Firefox:** usa su propio almacén. Hay que activar `security.enterprise_roots.enabled` o
  importar la raíz a mano.
- **Android:** se instala como certificado de usuario. El navegador la acepta; las apps, solo si lo
  declaran.

## Emitir certificados

**A mano**, en el servidor de la CA o en un equipo con `step ca bootstrap` hecho:

```bash
step ca certificate 10.0.0.10 srv.crt srv.key --san 10.0.0.10 \
  --provisioner admin --provisioner-password-file /etc/step-ca/provisioner-password.txt
# en el servidor que lo usa, renovación continua:
step ca renew --daemon --exec "systemctl reload nginx" srv.crt srv.key
```

Un certificado ya caducado no se renueva: se emite de nuevo.

**Por ACME** con [acme.sh](https://github.com/acmesh-official/acme.sh), desde el servidor que usará
el certificado. Necesita el puerto 80 libre, o `--webroot` si ya hay un servidor web:

```bash
acme.sh --issue --standalone -d 10.0.0.10 \
  --server https://10.0.0.5/acme/acme/directory --ca-bundle /ruta/root_ca.crt
acme.sh --install-cert -d 10.0.0.10 \
  --key-file /etc/ssl/private/srv.key --fullchain-file /etc/ssl/certs/srv.pem \
  --reloadcmd "systemctl reload nginx"
```

## Actualizar

```bash
cd /root
curl -fsSLO https://raw.githubusercontent.com/mtandazo35/step-ca-installer/main/actualizar.sh
bash actualizar.sh
```

Hace un respaldo de `/etc/step-ca` y de la unidad, actualiza los paquetes, reinicia y comprueba con
`step ca health`. Si la CA no responde, reinstala la versión anterior. Si tampoco así responde,
indica cómo restaurar el respaldo.

## Registros

- Instalador: `/root/step-ca-install.log`
- Actualización: `/root/step-ca-actualizar.log`
- Servicio: `journalctl -u step-ca`

## Cambiar la política o la duración después

Se edita `/etc/step-ca/config/ca.json` (copia antes, a `/root/backups`) y luego
`systemctl restart step-ca`. Los cambios en provisioners se aplican también con
`systemctl reload step-ca`, que manda un `SIGHUP`.

## Pendiente de comprobar en la primera instalación

- Que `step ca init` no pida nada por consola con todas las opciones dadas.
- Que la política no impida arrancar a la CA con su propio certificado.
- Que `step ca health` funcione tal cual con el `defaults.json` que deja `step ca init`.
