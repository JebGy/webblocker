# WebBlock Enterprise

Sistema integral de telemetría de navegación, control de ancho de banda satelital y mitigación de distracciones para faenas y organizaciones conectadas mediante Starlink. Permite al administrador monitorear en tiempo real qué dominios visitan los usuarios, bloquear sitios, identificar a los operadores de cada terminal, y rotar claves API de forma remota — todo sin tocar físicamente los equipos.

**Versión actual del agente: `1.1.3`**

---

## Características Principales

- **Agente Ligero en PowerShell** — Corre en segundo plano como Tarea Programada persistente en Windows, con tolerancia a micro-caídas satelitales mediante cola local JSON (`%ProgramData%\WebBlock`).
- **Auto-Actualización Desatendida (cada 20s)** — El agente consulta la versión vigente al servidor. Si detecta una superior, descarga el nuevo script, lo valida sintácticamente (AST anti-brick) y lo reemplaza en caliente sin intervención humana.
- **Protección Anti-Brick** — Validación AST con `[System.Management.Automation.Language.Parser]` antes de reemplazar el script en disco. Si hay un microcorte durante la descarga, la actualización se cancela y el proceso sigue funcionando.
- **Heartbeat Rápido (10s)** — El agente hace un ping al servidor cada 10 segundos, permitiendo que los comandos remotos (bloqueos, solicitudes de identificación, rotación de claves) surtan efecto en segundos.
- **Identificación Remota de Usuarios** — El administrador puede pulsar un botón en el dashboard para que en el equipo remoto aparezca un cuadro de diálogo nativo pidiendo **Nombre y DNI** al usuario. El formulario se abre en un proceso hijo visible (`-WindowStyle Normal`) para garantizar su visibilidad incluso cuando el agente corre oculto.
- **Rotación Remota de Claves API** — El servidor puede enviar una nueva API Key en el siguiente heartbeat. El equipo la confirma y adopta automáticamente sin reinstalación.
- **Bloqueo Inteligente con Expansión de CDN** — Al bloquear un dominio (ej. `tiktok.com`), el agente expande automáticamente subdominios y CDNs asociados, aplica redirección `0.0.0.0` en el archivo `hosts` y crea reglas en el Firewall de Windows (drop a nivel de kernel).
- **Protección Anti-Fuga (DoH)** — El instalador desactiva DNS-over-HTTPS en Chrome, Edge y Brave vía directivas de registro, impidiendo que los navegadores rodeen las restricciones.
- **Persistencia de Configuración** — La `ServerUrl`, `ApiKey`, usuario y DNI se conservan en `%ProgramData%\WebBlock\config.json` y sobreviven a todas las actualizaciones.
- **Cola Offline con Backoff Exponencial** — La telemetría se acumula localmente durante caídas satelitales y se sincroniza al recuperar el enlace.
- **Dashboard Streamlit** — Panel de control en tiempo real: dispositivos online/offline, gestión de bloqueos, solicitud de identificación, rotación de claves y métricas de navegación.
- **API FastAPI** — Endpoints protegidos con `X-Agent-Key` / `X-Admin-Key`, ingesta batch, auto-update, exportación CSV para Excel y purga de registros antiguos.

---

## Arquitectura del Sistema

```
[ Terminales en Faena / Organización ]
       │  Agente PowerShell v1.1.3 (C:\Program Files\WebBlock\agent.ps1)
       │  ├─ Heartbeat cada 10s (acciones surten efecto en <10s)
       │  ├─ Auto-update cada 20s con validación AST anti-brick
       │  ├─ Cuadro de identificación lanzado como proceso visible
       │  ├─ Bloqueo en hosts (0.0.0.0) + Firewall Windows (Kernel Drop)
       │  ├─ Muestreo de ventana activa (UIAutomation + heurística)
       │  └─ Cola offline JSON con backoff exponencial
       ▼
[ Enlace Satelital Starlink ]
       │  (micro-caídas absorbidas por buffer local)
       ▼
[ Servidor Central — FastAPI ] ───── [ Dashboard — Streamlit ]
       ├─ /api/heartbeat                ├─ Dispositivos online/offline
       ├─ /api/agent/version            ├─ Usuario y DNI por terminal
       ├─ /api/agent/download           ├─ Solicitud remota de identificación
       ├─ /api/devices/{id}/request-info├─ Rotación de claves API
       ├─ /api/devices/{id}/user        ├─ Gestión de dominios bloqueados
       ├─ /api/blocked-domains          ├─ Top dominios navegados
       ├─ /api/activity                 └─ Descarga de paquete instalador ZIP
       ├─ /api/metrics/export-csv
       └─ /api/admin/cleanup
       ▼
[ PostgreSQL — Base de Datos ]
       ├─ devices  (serial, brand, ip, ssid, version, usuario, DNI, keys)
       ├─ blocked_domains  (dominio, activo, fecha)
       └─ web_activity  (device_id, domain, duration_seconds, logged_at)
```

---

## Estructura del Repositorio

```
webblock/
├── client/
│   ├── agent.ps1            # Agente Windows (PowerShell)
│   ├── install.ps1          # Instalador con GUI y modo silencioso
│   ├── uninstall.ps1        # Desinstalador limpio
│   └── deploy_silent.bat    # Wrapper para despliegue masivo (Intune/GPO)
├── server/
│   ├── main.py              # API FastAPI
│   ├── dashboard_streamlit.py  # Dashboard de control
│   ├── test_server.py       # Suite de tests end-to-end
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── .env                 # Variables de entorno (no se sube a git)
│   ├── .env.example
│   └── client/              # Copia del cliente servida para auto-update
├── deploy.ps1               # Trigger de re-despliegue en Easypanel
├── docker-compose.yml
└── README.md
```

---

## Puesta en Marcha Rápida

### 1. Servidor Backend (FastAPI)

```bash
cd server
pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Swagger UI disponible en `http://localhost:8000/docs`.

### 2. Dashboard Streamlit

```bash
cd server
streamlit run dashboard_streamlit.py --server.port 8501
```

Dashboard disponible en `http://localhost:8501`.

### 3. Con Docker Compose

```bash
docker-compose up --build
```

- API en `:8000`
- Dashboard en `:8501`

### 4. Agente Cliente (Windows)

**Instalación con GUI** — Abrir PowerShell como Administrador:

```powershell
powershell -ExecutionPolicy Bypass -File .\client\install.ps1
```

**Instalación silenciosa** (Intune / GPO / SCCM):

```cmd
.\client\deploy_silent.bat -ServerUrl "https://tu-servidor" -ApiKey "wb_agent_secret_2026" -Silent
```

**One-liner de red** (descargar e instalar desde el servidor):

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "Invoke-WebRequest -Uri 'https://tu-servidor/api/client/zip' -OutFile '$env:TEMP\wb.zip'; Expand-Archive '$env:TEMP\wb.zip' -DestinationPath '$env:TEMP\wb' -Force; & '$env:TEMP\wb\instalar_automatico.bat'"
```

---

## Variables de Entorno

| Variable | Descripción | Valor por defecto |
|---|---|---|
| `DATABASE_URL` | Conexión PostgreSQL o SQLite | `sqlite:///./webblock.db` |
| `AGENT_API_KEY` | Clave requerida para los agentes cliente | `wb_agent_secret_2026` |
| `ADMIN_API_KEY` | Clave maestra para mutaciones y purga | `wb_admin_secret_2026` |
| `LATEST_AGENT_VERSION` | Versión vigente servida para auto-actualización | `1.1.3` |
| `SERVER_NAME` | Nombre de la organización mostrado en el dashboard y en el cuadro de identificación del usuario | `WebBlock Enterprise` |
| `EASYPANEL_DEPLOY_WEBHOOK` | URL de webhook para re-despliegue automático en Easypanel | _(vacío)_ |

---

## Flujo de Identificación Remota de Usuarios

1. Administrador pulsa **"📢 Pedir Nombre y DNI en la Terminal"** en el dashboard.
2. El servidor marca `request_user_info = True` en la base de datos para ese dispositivo.
3. En el siguiente heartbeat del agente (máx. **10 segundos**), el servidor devuelve `prompt_user_info: true`.
4. El agente lanza un **proceso hijo visible** (`-WindowStyle Normal`) con el formulario WinForms.
5. El usuario completa su Nombre y DNI y hace clic en **"Guardar Datos"**.
6. El agente sincroniza los datos al servidor en el siguiente heartbeat e informa en el log local.

---

## Parámetros del Agente

| Parámetro | Valor por defecto | Descripción |
|---|---|---|
| `-ServerUrl` | `http://localhost:8000` | URL del servidor central |
| `-ApiKey` | `wb_agent_secret_2026` | Clave de autenticación |
| `-HeartbeatIntervalSeconds` | `10` | Intervalo de heartbeat (comandos remotos surten efecto en este tiempo) |
| `-SyncBlocklistIntervalSeconds` | `10` | Frecuencia de sincronización de lista de bloqueo |
| `-UpdateCheckIntervalSeconds` | `20` | Frecuencia de comprobación de auto-update |
| `-SampleIntervalSeconds` | `3` | Frecuencia de muestreo de ventana activa |

---

## Historial de Versiones

| Versión | Cambios |
|---|---|
| **1.1.3** | Cuadro de identificación lanzado como proceso hijo visible para garantizar visibilidad con agente oculto |
| **1.1.2** | Heartbeat reducido a 10s; fix en lógica `request_user_info`; migración automática `blocked_domains.created_at` |
| **1.1.1** | Soporte de DNI, trigger remoto de identificación, gestión en dashboard |
| **1.1.0** | Nombre de usuario asignado, broadcast del nombre de servidor, cuadro de identificación |
| **1.0.9** | Versión del agente reportada en heartbeat y mostrada en dashboard |
| **1.0.2** | Auto-actualización E2E verificada; validación AST anti-brick |

---

## Tests

```bash
cd webblock
python -m pytest server/test_server.py -v
```

El test cubre el ciclo completo: heartbeat, versiones, bloqueos, identificación remota, rotación de claves y exportación CSV.

---

## Despliegue en Producción (Easypanel)

El repositorio está configurado para desplegarse automáticamente en Easypanel. Para forzar un re-despliegue manual:

```powershell
.\deploy.ps1
```

O disparar el webhook directamente desde cualquier cliente HTTP.
