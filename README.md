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
bash install.sh
```

Variables opcionales:

| Variable | Defecto | Qué es |
|---|---|---|
| `CA_DNS` | IP principal del servidor | IPs y nombres por los que se llega a la CA, separados por coma |
| `CA_NOMBRE` | `CA interna` | nombre que aparece en la raíz |
| `CA_PUERTO` | `443` | puerto HTTPS de la CA |
| `CA_DURACION` | `2160h` (90 días) | duración por defecto **y máxima** de los certificados |
| `CA_RANGOS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10` | IPs que la CA puede firmar |
| `CA_DOMINIOS` | vacío | nombres internos que puede firmar, p. ej. `*.lan` |

```bash
CA_DNS="10.0.0.5,ca.lan" CA_DOMINIOS="*.lan" bash install.sh
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
