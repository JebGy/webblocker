# WebBlock Enterprise ⚡

**Sistema integral de telemetría de navegación, optimización de ancho de banda satelital y mitigación de distracciones para faenas mineras conectadas mediante Starlink.**

---

## 🌟 Características Principales

- **Agente Ligero en PowerShell:** Corre en segundo plano como Tarea Programada persistente en Windows, tolerante a caídas satelitales mediante cola local JSON (`%ProgramData%\WebBlock`).
- **Bloqueo Inteligente y Expansión de CDNs:** Al bloquear un dominio (ej. `youtube.com` o `youtu.be`), el agente expande y bloquea automáticamente subdominios y CDNs (`googlevideo.com`, `ytimg.com`, `tiktokcdn.com`, etc.) combinando redirección en `hosts` (`0.0.0.0`) y reglas en el Firewall de Windows para corte inmediato a nivel de kernel.
- **Protección Anti-Fugas (DoH):** El instalador desactiva automáticamente DNS-over-HTTPS en Chrome, Edge y Brave mediante directivas de registro corporativas, evitando que los navegadores burlen las restricciones.
- **Panel de Instalación Gráfico (GUI):** Ventana nativa en Windows Forms para configurar la URL del servidor y API Key con test de conexión antes de instalar, más modo silencioso para despliegues masivos vía Microsoft Intune / GPO.
- **API FastAPI de Alto Rendimiento:** Endpoints protegidos con autenticación `X-Agent-Key` y `X-Admin-Key`, ingesta en lotes (batch), exportación de auditoría en CSV nativo compatible con Excel y job de purga de base de datos.
- **Dashboard Ejecutivo en Next.js 16:** Interfaz en tiempo real con Tailwind CSS v4 para visualizar terminales online/offline, ranking de sitios más visitados con barras proporcionales, gestión de lista negra con 1 clic y descarga de reportes.

---

## 🏗️ Arquitectura del Sistema

```
[ Terminales en Faena Minera ]
       │  Agente PowerShell (C:\Program Files\WebBlock)
       │  - Anti-Tamper: Permisos NTFS de solo lectura para usuarios estándar
       │  - Directiva corporativa: DoH deshabilitado en Chrome/Edge/Brave
       │  - Bloqueo en hosts (0.0.0.0) + Firewall de Windows (Kernel Drop)
       │  - Muestreo de ventana activa (UIAutomation + Heurística)
       │  - Cola local JSON en %ProgramData%\WebBlock con backoff exponencial
       ▼
[ Enlace Satelital Starlink ]
       │  (Micro-caídas absorbidas por el buffer local)
       ▼
[ Servidor Central (FastAPI) ] ─── [ Dashboard Gerencial (Next.js 16) ]
       │  - Sincronización rápida (10s)     - KPIs en vivo y Ranking de Tráfico
       │  - Ingesta en lote (Batch)          - Bloqueo en 1 clic (+Presets)
       │  - API Keys Zero-Trust              - Exportación CSV para Excel
       │  - Purga de logs antiguos           - Mantenimiento de BD
       ▼
[ Base de Datos PostgreSQL / SQLite ]
       - devices, blocked_domains, web_activity
```

---

## 🚀 Puesta en Marcha Rápida

### 1. Servidor Backend (FastAPI)
```bash
cd server
pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```
*Swagger UI interactivo disponible en `http://localhost:8000/docs`.*

### 2. Panel de Control Dashboard (Next.js)
```bash
cd dashboard/webblockfront
bun install # o npm install
bun run dev  # o npm run dev
```
*Dashboard disponible en `http://localhost:3000`.*

### 3. Agente Cliente (Windows)

#### Modo Técnico / Local (Con Panel Visual):
Abrir **PowerShell como Administrador** en el equipo a monitorear:
```powershell
powershell -ExecutionPolicy Bypass -File .\client\install.ps1
```
1. Ingresa la URL de tu servidor y la API Key.
2. Haz clic en **"Probar Conexión"** para verificar el enlace.
3. Haz clic en **"Instalar Servicio"**.

#### Modo Despliegue Silencioso (Intune / GPO / SCCM):
```cmd
.\client\deploy_silent.bat -ServerUrl "http://tu-servidor:8000" -ApiKey "wb_agent_secret_2026" -Silent
```

---

## 🔒 Variables de Entorno

| Variable | Ubicación | Descripción | Valor por defecto |
|---|---|---|---|
| `DATABASE_URL` | `server/.env` | Conexión PostgreSQL o SQLite local | `sqlite:///./webblock.db` |
| `AGENT_API_KEY` | `server/.env` | Clave requerida para los agentes cliente | `wb_agent_secret_2026` |
| `ADMIN_API_KEY` | `server/.env` | Clave maestra para mutaciones y purga | `wb_admin_secret_2026` |
| `NEXT_PUBLIC_API_URL` | `dashboard/.../.env.local` | Endpoint del backend para el frontend | `http://localhost:8000` |
| `NEXT_PUBLIC_ADMIN_KEY` | `dashboard/.../.env.local` | Clave de administración para el dashboard | `wb_admin_secret_2026` |

---

## 📄 Documentación Completa

Para detalles a fondo del esquema relacional, endpoints REST, directivas de registro y parámetros de configuración, consulta [docs.md](docs.md).
