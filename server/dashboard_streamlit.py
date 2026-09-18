import os
import io
import zipfile
import streamlit as st
import pandas as pd
from main import engine, SessionLocal, BlockedDomain, clean_domain_input, AGENT_API_KEY, Device, LATEST_AGENT_VERSION, SERVER_NAME

st.set_page_config(page_title=f"{SERVER_NAME} Monitor", layout="wide")
st.title(f"🛡️ {SERVER_NAME} Live Monitor (Servidor v{LATEST_AGENT_VERSION})")

# --- Paquete de Instalación para Clientes ---
with st.expander("📦 Despliegue en Terminales Windows (Descargar / Copiar Enlace)", expanded=True):
    default_url = os.getenv("SERVER_URL", "http://localhost:8000")
    col_u, col_k = st.columns([2, 1])
    with col_u:
        server_url = st.text_input("URL del Servidor API (donde reportarán los agentes):", value=default_url).rstrip("/")
    with col_k:
        api_key = st.text_input("API Key del Agente:", value=AGENT_API_KEY)

    # Generación en memoria del paquete ZIP preconfigurado
    client_dir = os.path.join(os.path.dirname(__file__), "client")
    if not os.path.exists(client_dir):
        client_dir = os.path.join(os.path.dirname(__file__), "..", "client")

    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as z:
        for fname in ["agent.ps1", "install.ps1", "deploy_silent.bat", "uninstall.ps1"]:
            fpath = os.path.join(client_dir, fname)
            if os.path.exists(fpath):
                z.write(fpath, arcname=fname)
        bat = (
            "@echo off\r\n"
            "net session >nul 2>&1\r\n"
            "if %errorlevel% neq 0 (\r\n"
            '    echo Elevando privilegios de Administrador...\r\n'
            '    powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "Start-Process cmd -ArgumentList \'/c \"\"%~f0\"\"\' -Verb RunAs"\r\n'
            "    exit /b\r\n"
            ")\r\n"
            "echo Instalando WebBlock Enterprise Agent (Bypass de directivas activo)...\r\n"
            f'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1" -ServerUrl "{server_url}" -ApiKey "{api_key}" -Silent\r\n'
            "echo Instalacion completada exitosamente.\r\n"
            "timeout /t 5\r\n"
        )
        z.writestr("instalar_automatico.bat", bat)
    zip_bytes = zip_buffer.getvalue()

    c_btn1, c_btn2 = st.columns([1, 2])
    with c_btn1:
        st.download_button(
            label="📥 Descargar Paquete (.zip)",
            data=zip_bytes,
            file_name="WebBlock-Client.zip",
            mime="application/zip",
            use_container_width=True
        )
    with c_btn2:
        zip_link = f"{server_url}/api/client/zip"
        st.text_input("Enlace directo al ZIP:", value=zip_link, disabled=True)

    st.info("💡 **Anti-Restricciones:** El archivo `instalar_automatico.bat` dentro del ZIP eleva permisos y usa `-ExecutionPolicy Bypass` automáticamente. Funciona con **doble clic** aunque Windows tenga bloqueada la ejecución de scripts.")

    st.caption("Comando directo desde CMD o PowerShell (ignora la política de scripts):")
    cmd_one_liner = f'powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "Invoke-WebRequest -Uri \'{server_url}/api/client/zip\' -OutFile \'$env:TEMP\\wb.zip\'; Expand-Archive \'$env:TEMP\\wb.zip\' -DestinationPath \'$env:TEMP\\wb\' -Force; & \'$env:TEMP\\wb\\instalar_automatico.bat\'"'
    st.code(cmd_one_liner, language="powershell")

st.divider()

# --- Gestión de Bloqueos ---
st.subheader("🚫 Dominios Bloqueados")
col_add, col_del = st.columns(2)

with col_add:
    with st.form("add_block", clear_on_submit=True):
        new_d = st.text_input("Bloquear Dominio (ej. tiktok.com, youtube.com)")
        if st.form_submit_button("➕ Bloquear") and new_d:
            domain = clean_domain_input(new_d)
            if domain and "." in domain:
                with SessionLocal() as db:
                    row = db.query(BlockedDomain).filter(BlockedDomain.domain == domain).first()
                    if row: row.is_active = True
                    else: db.add(BlockedDomain(domain=domain, is_active=True))
                    db.commit()
                st.success(f"Bloqueado: {domain}")
                st.rerun()

df_blocked = pd.read_sql("SELECT domain, is_active, added_by FROM blocked_domains ORDER BY is_active DESC, domain ASC", engine)

with col_del:
    if not df_blocked.empty:
        selected = st.selectbox("Seleccionar dominio de la lista", df_blocked["domain"])
        c1, c2 = st.columns(2)
        if c1.button("🔄 Alternar Activo/Inactivo"):
            with SessionLocal() as db:
                item = db.query(BlockedDomain).filter(BlockedDomain.domain == selected).first()
                if item: item.is_active = not item.is_active; db.commit()
            st.rerun()
        if c2.button("🗑️ Eliminar"):
            with SessionLocal() as db:
                db.query(BlockedDomain).filter(BlockedDomain.domain == selected).delete()
                db.commit()
            st.rerun()

if not df_blocked.empty:
    st.dataframe(df_blocked, use_container_width=True)
else:
    st.info("No hay dominios en la lista de bloqueo.")

st.divider()

# --- Dispositivos y Control de Claves ---
st.subheader("💻 Dispositivos Conectados y Usuarios Asignados")
df_devices = pd.read_sql("SELECT serial_number, assigned_user, brand, version, last_ip, current_key, pending_key, last_ping FROM devices ORDER BY last_ping DESC LIMIT 50", engine)

if not df_devices.empty:
    st.dataframe(df_devices, use_container_width=True)

    c_u1, c_u2 = st.columns(2)
    with c_u1:
        with st.expander("👤 Asignar / Modificar Usuario Responsable", expanded=False):
            target_u_dev = st.selectbox("Seleccionar Terminal:", df_devices["serial_number"].unique(), key="sel_user_dev")
            user_val = df_devices.loc[df_devices["serial_number"] == target_u_dev, "assigned_user"].values
            current_u_val = user_val[0] if len(user_val) > 0 and pd.notna(user_val[0]) else ""
            new_u_name = st.text_input("Nombre de Usuario / Cargo:", value=current_u_val, placeholder="ej. Juan Pérez - Operaciones Mina", key="txt_user_name")
            if st.button("💾 Guardar Usuario") and new_u_name:
                with SessionLocal() as db:
                    db.query(Device).filter(Device.serial_number == target_u_dev).update({Device.assigned_user: new_u_name.strip()})
                    db.commit()
                st.success(f"Usuario '{new_u_name.strip()}' asignado a {target_u_dev}!")
                st.rerun()

    with c_u2:
        with st.expander("🔑 Rotación Remota de Claves API", expanded=False):
            dev_options = ["Todos los Equipos"] + list(df_devices["serial_number"].unique())
            target_dev = st.selectbox("Seleccionar Terminal:", dev_options, key="sel_key_dev")
            new_key = st.text_input("Nueva API Key a Enviar:", placeholder="ej. wb_agent_2026_faena", key="txt_new_key")
            if st.button("🚀 Asignar Clave") and new_key:
                with SessionLocal() as db:
                    if target_dev == "Todos los Equipos":
                        db.query(Device).update({Device.pending_key: new_key.strip()})
                    else:
                        db.query(Device).filter(Device.serial_number == target_dev).update({Device.pending_key: new_key.strip()})
                    db.commit()
                st.success("Clave programada. El equipo la adoptará en su siguiente heartbeat.")
                st.rerun()
else:
    st.info("Sin dispositivos conectados todavía.")

st.divider()

# --- Telemetría y Métricas ---
col1, col2 = st.columns(2)
with col1:
    st.subheader("Top Dominios")
    top = pd.read_sql("SELECT domain, SUM(duration_seconds) as total_seg FROM web_activity GROUP BY domain ORDER BY total_seg DESC LIMIT 10", engine)
    if not top.empty:
        st.bar_chart(top.set_index("domain"))
    else:
        st.info("Sin datos de navegación aún.")

with col2:
    st.subheader("Tráfico Reciente en Vivo")
    st.dataframe(pd.read_sql("SELECT logged_at, domain, duration_seconds, device_id FROM web_activity ORDER BY logged_at DESC LIMIT 50", engine), use_container_width=True)
