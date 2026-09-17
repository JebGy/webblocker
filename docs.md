# WebBlock Enterprise — Documentación Técnica

Sistema centralizado de telemetría de navegación, optimización de ancho de banda y bloqueo de distracciones para unidades mineras conectadas mediante Starlink.

---

## 1. Arquitectura General y Seguridad

```
[ Unidades Mineras / PCs Clientes ]
       │  (Agente PowerShell en C:\Program Files\WebBlock)
       │  - Autenticación: Header X-Agent-Key
       │  - Anti-Tamper: Permisos NTFS de solo lectura para usuarios estándar
       │  - Directiva corporativa: DoH (DNS-over-HTTPS) deshabilitado en Chrome/Edge/Brave
       │  - Doble bloqueo: Archivo hosts (0.0.0.0) + Firewall de Windows (Kernel Drop)
       │  - Cola local JSON en %ProgramData%\WebBlock con backoff exponencial
       ▼
[ Enlace Starlink ]
       │  (Micro-caídas absorbidas por el buffer local)
       ▼
[ Servidor Central (FastAPI) ]
       │  - Endpoints protegidos con AGENT_API_KEY y ADMIN_API_KEY
       │  - Ingesta batch y sincronización rápida de lista negra (10s)
       │  - Exportación de auditoría en CSV nativo
       │  - Job de purga y retención de logs antiguos (>60 días)
       ▼
[ Base de Datos PostgreSQL / SQLite ]
       - devices, blocked_domains, web_activity
```

---

## 2. Estructura del Repositorio

```
webblock/
├── client/
│   ├── agent.ps1          # Agente cliente con backoff, monitoreo y firewall
│   ├── install.ps1        # Instalador visual (GUI Windows Forms) y silencioso (-Silent)
│   ├── deploy_silent.bat  # Script para despliegue masivo vía Intune / GPO / SCCM
│   └── uninstall.ps1      # Desinstalador limpio
├── server/
│   ├── main.py            # API FastAPI con seguridad, auth, exportación y cleanup
│   ├── requirements.txt   # Dependencias mínimas
│   ├── Dockerfile         # Imagen optimizada Python slim
│   ├── test_server.py     # Suite de autoverificación (100% aprobada)
│   └── .env               # Configuración local de base de datos y llaves
├── dashboard/             # Proyecto frontend (Next.js 16 + Tailwind CSS v4)
│   └── webblockfront/     # Panel de gerencia con métricas en tiempo real y CSV
├── docker-compose.yml     # Orquestación Docker para servidor
└── docs.md                # Esta documentación
```

---

## 3. Seguridad & Variables de Entorno

| Variable | Descripción | Valor por defecto |
|---|---|---|
| `DATABASE_URL` | Cadena de conexión PostgreSQL o SQLite | `sqlite:///./webblock.db` |
| `AGENT_API_KEY` | Clave secreta requerida para los agentes cliente | `wb_agent_secret_2026` |
| `ADMIN_API_KEY` | Clave maestra para crear/borrar bloqueos y purgar BD | `wb_admin_secret_2026` |

Los endpoints de modificación (`POST/PATCH/DELETE /api/blocked-domains` y `POST /api/admin/cleanup`) rechazan cualquier petición sin `X-Admin-Key` devolviendo `401 Unauthorized`.

---

## 4. Agente Cliente: Instalación y Operación

### Modo 1: Instalación Interactiva con Panel Visual (Técnico / Local)
Abre **PowerShell como Administrador** y ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File .\client\install.ps1
```

Se abrirá una **ventana de Windows Forms** donde puedes:
1. Especificar la **URL del Servidor Central** (ej. `http://localhost:8000` o `https://api.tu-empresa.com`).
2. Introducir la **API Key de Agente**.
3. Hacer clic en **"Probar Conexión"** para verificar el enlace satelital antes de instalar.
4. Hacer clic en **"Instalar Servicio"** para registrar la tarea de inicio automático.

### Modo 2: Despliegue Masivo Silencioso (Intune / GPO / SCCM)
Para distribuir de forma desatendida en 500 máquinas:

```cmd
deploy_silent.bat -ServerUrl "https://api.tu-empresa.com" -ApiKey "tu_clave_secreta" -Silent
```

### Características del Agente Instalado
- **Ruta de instalación:** `C:\Program Files\WebBlock\agent.ps1`
- **Anti-Tamper:** ACLs NTFS configuradas para que solo administradores puedan modificar la carpeta.
- **Bloqueo DoH:** Deshabilita DNS over HTTPS en el registro para Chrome, Edge y Brave (`DnsOverHttpsMode = "off"`), impidiendo que los navegadores burlen el archivo `hosts`.
- **Doble barrera de red:** Inyecta reglas en el Firewall de Windows para cortar paquetes en tiempo real hacia los CDNs de las páginas bloqueadas.

---

## 5. Dashboard de Gerencia (`http://localhost:3000`)

- **KPIs en tiempo real:** Terminales online, horas de distracción registradas y enlace Starlink.
- **Ranking de Dominios:** Visualización de porcentajes de uso con botón para bloquear en un clic.
- **Lista Negra Global:** Gestión de bloqueos con accesos rápidos (TikTok, YouTube, Facebook, etc.).
- **Exportación Excel:** Botón `📥 Exportar CSV` en la barra superior para descargar el reporte histórico consolidado de toda la mina.
- **Mantenimiento:** Botón `🧹 Purgar BD` para eliminar registros de más de 60 días y mantener óptima la base de datos PostgreSQL.
