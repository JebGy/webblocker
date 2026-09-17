"use client";

import { useEffect, useState, useTransition } from "react";

interface Device {
  id: string;
  serial_number: string;
  brand: string;
  last_ip: string;
  last_ssid: string;
  last_ping: string;
  is_online: boolean;
}

interface TopDomain {
  domain: string;
  total_seconds: number;
  hits: number;
}

interface BlockedDomain {
  id: string;
  domain: string;
  is_active: boolean;
  added_by: string;
}

interface DeviceActivity {
  domain: string;
  total_seconds: number;
  hits: number;
}

const API_BASE = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000";
const ADMIN_KEY = process.env.NEXT_PUBLIC_ADMIN_KEY || "wb_admin_secret_2026";

const PRESET_DOMAINS = [
  "tiktok.com",
  "facebook.com",
  "instagram.com",
  "youtube.com",
  "x.com",
  "netflix.com",
  "twitch.tv",
  "reddit.com",
];

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  if (mins < 60) return `${mins}m ${secs}s`;
  const hours = Math.floor(mins / 60);
  const remainMins = mins % 60;
  return `${hours}h ${remainMins}m`;
}

function timeAgo(isoString: string): string {
  const date = new Date(isoString);
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);
  if (seconds < 30) return "justo ahora";
  if (seconds < 60) return `hace ${seconds}s`;
  const mins = Math.floor(seconds / 60);
  if (mins < 60) return `hace ${mins}m`;
  const hours = Math.floor(mins / 60);
  return `hace ${hours}h`;
}

export default function DashboardPage() {
  const [devices, setDevices] = useState<Device[]>([]);
  const [topDomains, setTopDomains] = useState<TopDomain[]>([]);
  const [blockedDomains, setBlockedDomains] = useState<BlockedDomain[]>([]);
  const [selectedDevice, setSelectedDevice] = useState<Device | null>(null);
  const [deviceActivities, setDeviceActivities] = useState<DeviceActivity[]>([]);
  const [newDomainInput, setNewDomainInput] = useState("");
  const [loading, setLoading] = useState(true);
  const [apiOnline, setApiOnline] = useState(false);
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [, startTransition] = useTransition();

  const fetchDashboardData = async () => {
    try {
      const [resDev, resTop, resBlocked] = await Promise.all([
        fetch(`${API_BASE}/api/devices`),
        fetch(`${API_BASE}/api/metrics/top-domains?limit=15`),
        fetch(`${API_BASE}/api/blocked-domains/all`),
      ]);

      if (resDev.ok && resTop.ok && resBlocked.ok) {
        const [devData, topData, blockedData] = await Promise.all([
          resDev.json(),
          resTop.json(),
          resBlocked.json(),
        ]);
        startTransition(() => {
          setDevices(devData);
          setTopDomains(topData);
          setBlockedDomains(blockedData);
          setApiOnline(true);
          setLoading(false);
        });
      } else {
        setApiOnline(false);
      }
    } catch {
      setApiOnline(false);
    }
  };

  const loadDeviceDetail = async (device: Device) => {
    setSelectedDevice(device);
    try {
      const res = await fetch(`${API_BASE}/api/metrics/device/${device.id}`);
      if (res.ok) {
        const data = await res.json();
        setDeviceActivities(data);
      }
    } catch (e) {
      console.error(e);
    }
  };

  const handleAddBlocked = async (domainToBlock: string) => {
    const clean = domainToBlock.trim().toLowerCase();
    if (!clean) return;
    try {
      const res = await fetch(`${API_BASE}/api/blocked-domains`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Admin-Key": ADMIN_KEY,
        },
        body: JSON.stringify({ domain: clean, added_by: "Gerencia" }),
      });
      if (res.ok) {
        setNewDomainInput("");
        await fetchDashboardData();
      }
    } catch (e) {
      console.error(e);
    }
  };

  const handleToggleBlocked = async (id: string, currentStatus: boolean) => {
    try {
      await fetch(`${API_BASE}/api/blocked-domains/${id}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-Admin-Key": ADMIN_KEY,
        },
        body: JSON.stringify({ is_active: !currentStatus }),
      });
      await fetchDashboardData();
    } catch (e) {
      console.error(e);
    }
  };

  const handleDeleteBlocked = async (id: string) => {
    try {
      await fetch(`${API_BASE}/api/blocked-domains/${id}`, {
        method: "DELETE",
        headers: {
          "X-Admin-Key": ADMIN_KEY,
        },
      });
      await fetchDashboardData();
    } catch (e) {
      console.error(e);
    }
  };

  const handleDownloadCSV = () => {
    window.open(`${API_BASE}/api/metrics/export-csv`, "_blank");
  };

  const handleCleanupLogs = async () => {
    if (!confirm("¿Deseas purgar registros de navegación de más de 60 días para mantener óptima la base de datos?")) return;
    try {
      const res = await fetch(`${API_BASE}/api/admin/cleanup?days=60`, {
        method: "POST",
        headers: { "X-Admin-Key": ADMIN_KEY },
      });
      if (res.ok) {
        const data = await res.json();
        alert(`Mantenimiento completado: ${data.deleted_records} registros antiguos eliminados.`);
        await fetchDashboardData();
      }
    } catch (e) {
      console.error(e);
    }
  };

  useEffect(() => {
    fetchDashboardData();
    if (!autoRefresh) return;
    const interval = setInterval(fetchDashboardData, 5000);
    return () => clearInterval(interval);
  }, [autoRefresh]);

  const totalDistractionSeconds = topDomains.reduce((acc, d) => acc + d.total_seconds, 0);
  const onlineDevicesCount = devices.filter((d) => d.is_online).length;
  const activeBlocksCount = blockedDomains.filter((d) => d.is_active).length;
  const maxDomainSeconds = topDomains.length > 0 ? topDomains[0].total_seconds : 1;

  return (
    <div className="min-h-screen bg-neutral-950 text-neutral-100 font-sans p-4 md:p-8">
      {/* Top Header */}
      <header className="max-w-7xl mx-auto flex flex-col md:flex-row md:items-center justify-between gap-4 pb-6 border-b border-neutral-800">
        <div>
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 rounded-lg bg-emerald-500/20 border border-emerald-500/40 flex items-center justify-center font-bold text-emerald-400">
              ⚡
            </div>
            <h1 className="text-xl md:text-2xl font-bold tracking-tight">
              WebBlock <span className="text-emerald-400 font-normal text-sm md:text-base">| Telemetría Starlink</span>
            </h1>
          </div>
          <p className="text-xs md:text-sm text-neutral-400 mt-1">
            Control de ancho de banda y mitigación de distracciones en faenas mineras
          </p>
        </div>

        <div className="flex items-center gap-3">
          <div className="flex items-center gap-2 bg-neutral-900 border border-neutral-800 px-3 py-1.5 rounded-full text-xs">
            <span
              className={`w-2 h-2 rounded-full ${
                apiOnline ? "bg-emerald-400 animate-pulse" : "bg-rose-500"
              }`}
            />
            <span className={apiOnline ? "text-emerald-300" : "text-rose-400"}>
              {apiOnline ? "API Online" : "Desconectado"}
            </span>
          </div>

          <button
            onClick={() => setAutoRefresh(!autoRefresh)}
            className={`px-3 py-1.5 rounded-lg text-xs font-medium border transition-colors ${
              autoRefresh
                ? "bg-emerald-950/40 border-emerald-700/50 text-emerald-300"
                : "bg-neutral-900 border-neutral-800 text-neutral-400 hover:text-white"
            }`}
          >
            {autoRefresh ? "Auto-refresh ON (5s)" : "Auto-refresh OFF"}
          </button>

          <button
            onClick={fetchDashboardData}
            className="px-3 py-1.5 rounded-lg text-xs font-medium bg-neutral-800 hover:bg-neutral-700 text-neutral-200 border border-neutral-700 transition"
          >
            Refrescar
          </button>

          <button
            onClick={handleDownloadCSV}
            className="px-3 py-1.5 rounded-lg text-xs font-medium bg-emerald-900/40 hover:bg-emerald-800/50 text-emerald-300 border border-emerald-700/50 transition flex items-center gap-1.5"
            title="Descargar reporte para Excel"
          >
            📥 Exportar CSV
          </button>

          <button
            onClick={handleCleanupLogs}
            className="px-2.5 py-1.5 rounded-lg text-xs font-medium bg-neutral-900 hover:bg-rose-950/40 text-neutral-400 hover:text-rose-300 border border-neutral-800 hover:border-rose-800/50 transition"
            title="Purgar logs antiguos (>60 días)"
          >
            🧹 Purgar BD
          </button>
        </div>
      </header>

      {/* KPI Stats Cards */}
      <section className="max-w-7xl mx-auto grid grid-cols-2 lg:grid-cols-4 gap-4 my-6">
        <div className="bg-neutral-900/60 border border-neutral-800/80 rounded-xl p-4">
          <p className="text-xs text-neutral-400 font-medium">Equipos Monitoreados</p>
          <div className="flex items-baseline gap-2 mt-2">
            <span className="text-2xl md:text-3xl font-bold text-white">{devices.length}</span>
            <span className="text-xs font-semibold text-emerald-400">
              ({onlineDevicesCount} online)
            </span>
          </div>
          <p className="text-[11px] text-neutral-500 mt-1">Conexión en faenas mineras</p>
        </div>

        <div className="bg-neutral-900/60 border border-neutral-800/80 rounded-xl p-4">
          <p className="text-xs text-neutral-400 font-medium">Tiempo de Foco Registrado</p>
          <p className="text-2xl md:text-3xl font-bold text-amber-300 mt-2">
            {formatDuration(totalDistractionSeconds)}
          </p>
          <p className="text-[11px] text-neutral-500 mt-1">Acumulado en navegadores</p>
        </div>

        <div className="bg-neutral-900/60 border border-neutral-800/80 rounded-xl p-4">
          <p className="text-xs text-neutral-400 font-medium">Reglas de Bloqueo Activas</p>
          <div className="flex items-baseline gap-2 mt-2">
            <span className="text-2xl md:text-3xl font-bold text-rose-400">{activeBlocksCount}</span>
            <span className="text-xs text-neutral-400">de {blockedDomains.length}</span>
          </div>
          <p className="text-[11px] text-neutral-500 mt-1">Inyectados en archivo hosts</p>
        </div>

        <div className="bg-neutral-900/60 border border-neutral-800/80 rounded-xl p-4">
          <p className="text-xs text-neutral-400 font-medium">Enlace Starlink Principal</p>
          <p className="text-lg md:text-xl font-semibold text-sky-400 truncate mt-2">
            {devices[0]?.last_ssid || "Sin datos"}
          </p>
          <p className="text-[11px] text-neutral-500 mt-1">IP: {devices[0]?.last_ip || "—"}</p>
        </div>
      </section>

      {/* Main Grid */}
      <div className="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-12 gap-6">
        {/* Left Column: Top Domains & Devices (7 cols) */}
        <div className="lg:col-span-7 space-y-6">
          {/* Top Visited Domains */}
          <div className="bg-neutral-900/60 border border-neutral-800/80 rounded-xl p-5">
            <div className="flex items-center justify-between mb-4">
              <div>
                <h2 className="text-base font-semibold text-white">Top Dominios Más Visitados</h2>
                <p className="text-xs text-neutral-400">Sitios con mayor consumo de tiempo activo</p>
              </div>
              <span className="text-xs bg-neutral-800 px-2.5 py-1 rounded text-neutral-300">
                {topDomains.length} dominios
              </span>
            </div>

            {topDomains.length === 0 ? (
              <div className="text-center py-10 text-neutral-500 text-xs">
                No hay actividad registrada aún. Inicia el agente cliente en tu equipo para recopilar.
              </div>
            ) : (
              <div className="space-y-3">
                {topDomains.map((item, idx) => {
                  const percentage = Math.min(100, Math.round((item.total_seconds / maxDomainSeconds) * 100));
                  const isBlocked = blockedDomains.some((b) => b.domain === item.domain && b.is_active);

                  return (
                    <div key={item.domain} className="space-y-1">
                      <div className="flex items-center justify-between text-xs">
                        <div className="flex items-center gap-2">
                          <span className="text-neutral-500 font-mono w-4">{idx + 1}.</span>
                          <span className="font-medium text-neutral-200">{item.domain}</span>
                          {isBlocked && (
                            <span className="text-[10px] bg-rose-950/60 text-rose-300 border border-rose-800/50 px-1.5 py-0.5 rounded">
                              Bloqueado
                            </span>
                          )}
                        </div>
                        <div className="flex items-center gap-3">
                          <span className="text-neutral-400 font-mono">
                            {formatDuration(item.total_seconds)}
                          </span>
                          {!isBlocked && (
                            <button
                              onClick={() => handleAddBlocked(item.domain)}
                              className="text-[11px] text-rose-400 hover:text-rose-300 underline"
                            >
                              Bloquear
                            </button>
                          )}
                        </div>
                      </div>
                      <div className="w-full h-2 bg-neutral-800 rounded-full overflow-hidden">
                        <div
                          className={`h-full rounded-full transition-all duration-500 ${
                            isBlocked ? "bg-rose-500" : "bg-emerald-500"
                          }`}
                          style={{ width: `${percentage}%` }}
                        />
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          {/* Devices Table */}
          <div className="bg-neutral-900/60 border border-neutral-800/80 rounded-xl p-5">
            <div className="flex items-center justify-between mb-4">
              <div>
                <h2 className="text-base font-semibold text-white">Equipos en Faena</h2>
                <p className="text-xs text-neutral-400">Terminales mineras reportando telemetría</p>
              </div>
              <span className="text-xs bg-neutral-800 px-2.5 py-1 rounded text-neutral-300">
                {devices.length} terminales
              </span>
            </div>

            {devices.length === 0 ? (
              <div className="text-center py-8 text-neutral-500 text-xs">
                No hay equipos conectados. Ejecuta <code>install.ps1</code> en las máquinas clientes.
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-xs">
                  <thead className="border-b border-neutral-800 text-neutral-400 font-medium">
                    <tr>
                      <th className="pb-2">Estado</th>
                      <th className="pb-2">Serie / HW</th>
                      <th className="pb-2">Marca</th>
                      <th className="pb-2">IP</th>
                      <th className="pb-2">SSID Starlink</th>
                      <th className="pb-2">Último Ping</th>
                      <th className="pb-2 text-right">Acción</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-neutral-800/50">
                    {devices.map((d) => (
                      <tr key={d.id} className="hover:bg-neutral-800/30 transition">
                        <td className="py-2.5">
                          <span
                            className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-medium ${
                              d.is_online
                                ? "bg-emerald-950/60 text-emerald-400 border border-emerald-800/50"
                                : "bg-neutral-800 text-neutral-400"
                            }`}
                          >
                            <span
                              className={`w-1.5 h-1.5 rounded-full ${
                                d.is_online ? "bg-emerald-400" : "bg-neutral-500"
                              }`}
                            />
                            {d.is_online ? "Online" : "Offline"}
                          </span>
                        </td>
                        <td className="py-2.5 font-mono text-neutral-200">{d.serial_number}</td>
                        <td className="py-2.5 text-neutral-300">{d.brand}</td>
                        <td className="py-2.5 font-mono text-neutral-400">{d.last_ip}</td>
                        <td className="py-2.5 text-sky-400">{d.last_ssid}</td>
                        <td className="py-2.5 text-neutral-400">{timeAgo(d.last_ping)}</td>
                        <td className="py-2.5 text-right">
                          <button
                            onClick={() => loadDeviceDetail(d)}
                            className="text-emerald-400 hover:text-emerald-300 font-medium"
                          >
                            Ver detalle
                          </button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>

        {/* Right Column: Blacklist Management & Device Activity Detail (5 cols) */}
        <div className="lg:col-span-5 space-y-6">
          {/* Blacklist Control */}
          <div className="bg-neutral-900/60 border border-neutral-800/80 rounded-xl p-5">
            <div className="mb-4">
              <h2 className="text-base font-semibold text-white">Lista Negra de Dominios</h2>
              <p className="text-xs text-neutral-400">
                Los clientes bloquean estos dominios cada 5 min vía archivo hosts
              </p>
            </div>

            {/* Quick Presets */}
            <div className="mb-3">
              <p className="text-[11px] text-neutral-500 mb-1.5">Bloqueo rápido:</p>
              <div className="flex flex-wrap gap-1.5">
                {PRESET_DOMAINS.map((preset) => {
                  const alreadyAdded = blockedDomains.some((b) => b.domain === preset);
                  return (
                    <button
                      key={preset}
                      disabled={alreadyAdded}
                      onClick={() => handleAddBlocked(preset)}
                      className={`text-[11px] px-2 py-1 rounded transition ${
                        alreadyAdded
                          ? "bg-neutral-800/40 text-neutral-600 border border-neutral-800 cursor-not-allowed"
                          : "bg-neutral-800 text-neutral-300 hover:bg-rose-950/40 hover:text-rose-300 hover:border-rose-800/50 border border-neutral-700/60"
                      }`}
                    >
                      +{preset}
                    </button>
                  );
                })}
              </div>
            </div>

            {/* Input form */}
            <form
              onSubmit={(e) => {
                e.preventDefault();
                handleAddBlocked(newDomainInput);
              }}
              className="flex gap-2 mb-4"
            >
              <input
                type="text"
                placeholder="ej: roblox.com"
                value={newDomainInput}
                onChange={(e) => setNewDomainInput(e.target.value)}
                className="flex-1 bg-neutral-950 border border-neutral-700/80 rounded-lg px-3 py-2 text-xs text-neutral-200 focus:outline-none focus:border-emerald-500 placeholder-neutral-600"
              />
              <button
                type="submit"
                className="bg-rose-600 hover:bg-rose-500 text-white font-medium px-3.5 py-2 rounded-lg text-xs transition"
              >
                Bloquear
              </button>
            </form>

            {/* Blocked domains list */}
            {blockedDomains.length === 0 ? (
              <div className="text-center py-6 text-neutral-500 text-xs">
                No hay dominios en la lista negra.
              </div>
            ) : (
              <div className="divide-y divide-neutral-800/60 max-h-80 overflow-y-auto pr-1">
                {blockedDomains.map((b) => (
                  <div key={b.id} className="py-2.5 flex items-center justify-between text-xs">
                    <div>
                      <p className="font-medium text-neutral-200">{b.domain}</p>
                      <p className="text-[10px] text-neutral-500">Agregado por: {b.added_by}</p>
                    </div>

                    <div className="flex items-center gap-2">
                      <button
                        onClick={() => handleToggleBlocked(b.id, b.is_active)}
                        className={`text-[10px] font-semibold px-2 py-0.5 rounded border transition ${
                          b.is_active
                            ? "bg-emerald-950/50 text-emerald-400 border-emerald-800/50"
                            : "bg-neutral-800 text-neutral-400 border-neutral-700"
                        }`}
                      >
                        {b.is_active ? "Activo" : "Pausado"}
                      </button>

                      <button
                        onClick={() => handleDeleteBlocked(b.id)}
                        className="text-neutral-500 hover:text-rose-400 p-1 transition"
                        title="Eliminar regla"
                      >
                        ✕
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Selected Device Activity Detail */}
          {selectedDevice && (
            <div className="bg-neutral-900/60 border border-emerald-800/40 rounded-xl p-5">
              <div className="flex items-center justify-between mb-3">
                <div>
                  <h3 className="text-sm font-semibold text-white">
                    Actividad: {selectedDevice.serial_number}
                  </h3>
                  <p className="text-xs text-neutral-400">
                    {selectedDevice.brand} | {selectedDevice.last_ip}
                  </p>
                </div>
                <button
                  onClick={() => setSelectedDevice(null)}
                  className="text-neutral-500 hover:text-neutral-300 text-xs"
                >
                  Cerrar
                </button>
              </div>

              {deviceActivities.length === 0 ? (
                <p className="text-xs text-neutral-500 py-3 text-center">
                  Sin actividad registrada para este equipo.
                </p>
              ) : (
                <div className="space-y-2 max-h-60 overflow-y-auto pr-1">
                  {deviceActivities.map((act) => (
                    <div
                      key={act.domain}
                      className="flex items-center justify-between bg-neutral-950/60 p-2 rounded text-xs"
                    >
                      <span className="text-neutral-200 font-medium">{act.domain}</span>
                      <div className="text-right">
                        <span className="font-mono text-emerald-400">
                          {formatDuration(act.total_seconds)}
                        </span>
                        <span className="text-neutral-500 text-[10px] ml-2">({act.hits} hits)</span>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
