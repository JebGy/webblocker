import streamlit as st
import pandas as pd
from main import engine

st.set_page_config(page_title="WebBlock Live", layout="wide")
st.title("🛡️ WebBlock Live Monitor")
if st.button("🔄 Actualizar Datos"):
    st.rerun()

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
