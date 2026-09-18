import streamlit as st
import pandas as pd
from main import engine, SessionLocal, BlockedDomain, clean_domain_input

st.set_page_config(page_title="WebBlock Live", layout="wide")
st.title("🛡️ WebBlock Live Monitor")

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
