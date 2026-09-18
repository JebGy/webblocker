import os
import io
import zipfile
import streamlit as st
import pandas as pd
from main import engine, SessionLocal, BlockedDomain, clean_domain_input, AGENT_API_KEY

st.set_page_config(page_title="WebBlock Live", layout="wide")
st.title("🛡️ WebBlock Live Monitor")

# --- Paquete de Instalación para Clientes ---
with st.expander("📦 Despliegue en Terminales Windows (Descargar / Copiar Enlace)", expanded=True):
    default_url = os.getenv("SERVER_URL", "https://governance-webblockserver.tc5u8q.easypanel.host")
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
        bat = f'@echo off\r\necho Instalando WebBlock Agent...\r\npowershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1" -ServerUrl "{server_url}" -ApiKey "{api_key}" -Silent\r\necho Instalacion completada exitosamente.\r\npause\r\n'
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

    st.caption("Comando para descargar e instalar en 1 paso desde PowerShell (Ejecutar como Administrador):")
    cmd_one_liner = f'powershell -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri \'{server_url}/api/client/zip\' -OutFile \'$env:TEMP\\wb.zip\'; Expand-Archive \'$env:TEMP\\wb.zip\' -DestinationPath \'$env:TEMP\\wb\' -Force; & \'$env:TEMP\\wb\\instalar_automatico.bat\'"'
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

# --- Telemetría y Métricas ---
col1, col2 = st.columns(2)
with col1:
    st.subheader("Dispositivos")
    st.dataframe(pd.read_sql("SELECT serial_number, brand, last_ip, last_ssid, last_ping FROM devices ORDER BY last_ping DESC LIMIT 20", engine), use_container_width=True)

with col2:
    st.subheader("Top Dominios")
    top = pd.read_sql("SELECT domain, SUM(duration_seconds) as total_seg FROM web_activity GROUP BY domain ORDER BY total_seg DESC LIMIT 10", engine)
    if not top.empty:
        st.bar_chart(top.set_index("domain"))
    else:
        st.info("Sin datos de navegación aún.")

st.subheader("Tráfico Reciente en Vivo")
st.dataframe(pd.read_sql("SELECT logged_at, domain, duration_seconds, device_id FROM web_activity ORDER BY logged_at DESC LIMIT 50", engine), use_container_width=True)
