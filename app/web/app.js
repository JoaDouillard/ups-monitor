'use strict';

// ============================================================
// Configuration Chart.js (thème sombre)
// ============================================================
Chart.defaults.color = '#7b7f94';
Chart.defaults.borderColor = '#2a2d3a';
Chart.defaults.font.family = "'Segoe UI', system-ui, sans-serif";
Chart.defaults.font.size = 11;

const COLORS = {
  green:  '#22c55e',
  yellow: '#eab308',
  orange: '#f97316',
  red:    '#ef4444',
  blue:   '#60a5fa',
  purple: '#a78bfa',
  muted:  '#7b7f94',
};

// ============================================================
// State
// ============================================================
let ws = null;
let chartMain = null;
let chartVoltage = null;
let chartHistoryBat = null;
let chartHistoryLoad = null;
let chartHistoryVoltage = null;
const MAX_LIVE_POINTS = 120; // ~1h à 30s/poll

// ============================================================
// Helpers
// ============================================================
const $ = (id) => document.getElementById(id);
const fmt = (v, unit = '', fallback = '—') =>
  v === null || v === undefined ? fallback : `${v}${unit}`;

function formatRuntime(minutes) {
  if (minutes === null || minutes === undefined) return '—';
  if (minutes >= 60) {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return `${h}h ${m.toString().padStart(2, '0')}min`;
  }
  return `${minutes} min`;
}

function formatTime(isoStr) {
  const d = new Date(isoStr);
  return d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function formatDateTime(isoStr) {
  const d = new Date(isoStr);
  return d.toLocaleString('fr-FR');
}

// ============================================================
// Authentification
// ============================================================
async function checkAuth() {
  try {
    const r = await fetch('/api/auth/me');
    return r.ok;
  } catch {
    return false;
  }
}

async function login(username, password) {
  const body = new URLSearchParams({ username, password });
  const r = await fetch('/api/auth/login', {
    method: 'POST',
    body,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  });
  if (!r.ok) {
    const data = await r.json().catch(() => ({}));
    throw new Error(data.detail || 'Identifiants incorrects');
  }
  return r.json();
}

async function logout() {
  await fetch('/api/auth/logout', { method: 'POST' });
  location.reload();
}

// ============================================================
// Navigation par onglets
// ============================================================
function initTabs() {
  document.querySelectorAll('.tab').forEach((btn) => {
    btn.addEventListener('click', () => {
      const tabId = btn.dataset.tab;
      document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
      document.querySelectorAll('.tab-content').forEach((c) => c.classList.remove('active'));
      btn.classList.add('active');
      $(`tab-${tabId}`).classList.add('active');

      if (tabId === 'history') loadHistory();
      if (tabId === 'alerts') loadAlerts();
      if (tabId === 'info') loadInfo();
    });
  });
}

// ============================================================
// Mise à jour du dashboard (depuis données live)
// ============================================================
function updateDashboard(d) {
  // --- Status badge ---
  const badge = $('status-badge');
  const statusText = $('status-text');
  badge.className = 'status-badge';

  if (!d.reachable) {
    badge.classList.add('status-critical');
    statusText.textContent = 'UPS INJOIGNABLE';
  } else if (d.output_source === 5) {
    badge.classList.add('status-battery');
    statusText.textContent = 'SUR BATTERIE';
  } else if (d.output_status === 2 || d.alarm_count > 0) {
    badge.classList.add('status-warning');
    statusText.textContent = `ALERTE (${d.alarm_count || 0} alarme${d.alarm_count > 1 ? 's' : ''})`;
  } else if (d.output_source === 3 && d.output_status === 3) {
    badge.classList.add('status-ok');
    statusText.textContent = 'SECTEUR — PROTÉGÉ';
  } else {
    badge.classList.add('status-unknown');
    statusText.textContent = d.output_source_label || 'Inconnu';
  }

  // --- Timestamp ---
  if (d.timestamp) {
    $('last-update').textContent = `Mis à jour : ${formatTime(d.timestamp)}`;
  }

  // --- Batterie ---
  const batPct = d.bat_capacity ?? 0;
  $('m-bat-capacity').textContent = fmt(d.bat_capacity, '%');
  $('m-bat-status').textContent = d.bat_abm_status_label || '—';
  const batBar = $('m-bat-bar');
  batBar.style.width = `${batPct}%`;
  batBar.style.background =
    batPct > 50 ? COLORS.green :
    batPct > 25 ? COLORS.yellow :
    batPct > 10 ? COLORS.orange : COLORS.red;

  // --- Autonomie ---
  $('m-runtime').textContent = formatRuntime(d.bat_runtime_seconds);
  $('m-bat-voltage').textContent = fmt(d.bat_voltage, ' V DC');

  // --- Charge ---
  const loadPct = d.output_load_percent ?? 0;
  $('m-load').textContent = fmt(d.output_load_percent, '%');
  $('m-power-watts').textContent = fmt(d.output_watts, ' W');
  const loadBar = $('m-load-bar');
  loadBar.style.width = `${loadPct}%`;
  loadBar.style.background =
    loadPct < 60 ? COLORS.green :
    loadPct < 80 ? COLORS.yellow : COLORS.red;

  // --- Source ---
  const src = d.output_source_label || '—';
  $('m-output-source').textContent = src;
  $('m-output-status').textContent = d.output_status_label || '—';

  // --- Détails entrée ---
  $('d-input-voltage').textContent    = fmt(d.input_voltage, ' V');
  $('d-input-frequency').textContent  = fmt(d.input_frequency, ' Hz');
  $('d-input-source').textContent     = d.input_source === 3 ? '✓ Secteur principal' : (d.input_source_label || '—');
  $('d-input-status').textContent     = d.input_status === 2 ? '✓ Correct' : (d.input_status_label || '—');

  // --- Détails sortie ---
  $('d-output-voltage').textContent   = fmt(d.output_voltage, ' V');
  $('d-output-frequency').textContent = fmt(d.output_frequency, ' Hz');
  $('d-output-watts').textContent     = fmt(d.output_watts, ' W');
  $('d-output-va').textContent        = fmt(d.output_va, ' VA');

  // --- Détails batterie ---
  $('d-bat-capacity').textContent  = fmt(d.bat_capacity, '%');
  $('d-bat-runtime').textContent   = formatRuntime(d.bat_runtime_seconds);
  $('d-bat-voltage').textContent   = fmt(d.bat_voltage, ' V DC');
  $('d-bat-failure').textContent   = d.bat_failure ? '⚠️ OUI' : '✓ Non';
  $('d-bat-aged').textContent      = d.bat_aged    ? '⚠️ OUI' : '✓ Non';
  $('d-alarm-count').textContent   = d.alarm_count ?? '0';
}

// ============================================================
// Graphiques live (dashboard)
// ============================================================
function initCharts() {
  const ctxMain = $('chart-main').getContext('2d');
  chartMain = new Chart(ctxMain, {
    type: 'line',
    data: {
      labels: [],
      datasets: [
        {
          label: 'Batterie (%)',
          data: [],
          borderColor: COLORS.green,
          backgroundColor: 'rgba(34,197,94,0.07)',
          fill: true,
          tension: 0.3,
          pointRadius: 0,
          borderWidth: 2,
          yAxisID: 'y',
        },
        {
          label: 'Charge (%)',
          data: [],
          borderColor: COLORS.yellow,
          backgroundColor: 'rgba(234,179,8,0.07)',
          fill: true,
          tension: 0.3,
          pointRadius: 0,
          borderWidth: 2,
          yAxisID: 'y',
        },
      ],
    },
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: true,
      plugins: { legend: { position: 'top' } },
      scales: {
        x: { ticks: { maxTicksLimit: 8 } },
        y: { min: 0, max: 100, ticks: { callback: (v) => `${v}%` } },
      },
    },
  });

  const ctxVolt = $('chart-voltage').getContext('2d');
  chartVoltage = new Chart(ctxVolt, {
    type: 'line',
    data: {
      labels: [],
      datasets: [
        {
          label: 'Tension entrée (V)',
          data: [],
          borderColor: COLORS.blue,
          tension: 0.3,
          pointRadius: 0,
          borderWidth: 2,
        },
        {
          label: 'Tension sortie (V)',
          data: [],
          borderColor: COLORS.purple,
          tension: 0.3,
          pointRadius: 0,
          borderWidth: 2,
        },
      ],
    },
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: true,
      plugins: { legend: { position: 'top' } },
      scales: {
        x: { ticks: { maxTicksLimit: 6 } },
        y: { ticks: { callback: (v) => `${v}V` } },
      },
    },
  });
}

function pushLivePoint(d) {
  if (!chartMain || !d.timestamp) return;
  const label = formatTime(d.timestamp);

  function trimAndPush(chart, ...values) {
    chart.data.labels.push(label);
    values.forEach((v, i) => chart.data.datasets[i].data.push(v));
    if (chart.data.labels.length > MAX_LIVE_POINTS) {
      chart.data.labels.shift();
      chart.data.datasets.forEach((ds) => ds.data.shift());
    }
    chart.update('none');
  }

  trimAndPush(chartMain, d.bat_capacity, d.output_load_percent);
  trimAndPush(chartVoltage, d.input_voltage, d.output_voltage);
}

// ============================================================
// Chargement initial des données live (dernières 2h)
// ============================================================
async function loadInitialHistory() {
  try {
    const r = await fetch('/api/history?hours=2');
    if (!r.ok) return;
    const readings = await r.json();
    readings.forEach((d) => {
      pushLivePoint(d);
    });
    if (readings.length > 0) {
      updateDashboard(readings[readings.length - 1]);
    }
  } catch (e) {
    console.warn('loadInitialHistory:', e);
  }
}

// ============================================================
// WebSocket live
// ============================================================
function connectWebSocket() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const url = `${proto}://${location.host}/api/ws/live`;
  ws = new WebSocket(url);

  ws.onopen = () => console.log('[WS] Connecté');

  ws.onmessage = (evt) => {
    try {
      const d = JSON.parse(evt.data);
      if (d.type === 'ping') return;
      updateDashboard(d);
      pushLivePoint(d);
    } catch (e) {
      console.warn('[WS] Parse error:', e);
    }
  };

  ws.onclose = (evt) => {
    if (evt.code === 4001) {
      console.warn('[WS] Non authentifié, reload');
      location.reload();
      return;
    }
    console.log('[WS] Déconnecté, reconnexion dans 5s…');
    setTimeout(connectWebSocket, 5000);
  };

  ws.onerror = () => ws.close();
}

// ============================================================
// Onglet Historique
// ============================================================
function makeHistoryCharts() {
  const makeChart = (id, label, color, unit = '') => {
    const ctx = $(id).getContext('2d');
    return new Chart(ctx, {
      type: 'line',
      data: { labels: [], datasets: [{ label, data: [], borderColor: color, tension: 0.2, pointRadius: 0, borderWidth: 2, fill: false }] },
      options: {
        animation: false, responsive: true, maintainAspectRatio: true,
        plugins: { legend: { position: 'top' } },
        scales: {
          x: { ticks: { maxTicksLimit: 10 } },
          y: { ticks: { callback: (v) => `${v}${unit}` } },
        },
      },
    });
  };

  chartHistoryBat     = makeChart('chart-history-bat',     'Batterie (%)',         COLORS.green,  '%');
  chartHistoryLoad    = makeChart('chart-history-load',    'Charge sortie (%)',    COLORS.yellow, '%');
  chartHistoryVoltage = makeChart('chart-history-voltage', 'Tension entrée (V)',   COLORS.blue,   'V');
}

async function loadHistory() {
  const hours = parseInt($('history-range').value, 10);
  try {
    const r = await fetch(`/api/history?hours=${hours}`);
    if (!r.ok) return;
    const readings = await r.json();

    const labels  = readings.map((d) => formatDateTime(d.timestamp));
    const bat     = readings.map((d) => d.bat_capacity);
    const load    = readings.map((d) => d.output_load_percent);
    const voltage = readings.map((d) => d.input_voltage);

    function refill(chart, lbl, vals) {
      chart.data.labels = lbl;
      chart.data.datasets[0].data = vals;
      chart.update();
    }

    if (!chartHistoryBat) makeHistoryCharts();
    refill(chartHistoryBat, labels, bat);
    refill(chartHistoryLoad, labels, load);
    refill(chartHistoryVoltage, labels, voltage);
  } catch (e) {
    console.warn('loadHistory:', e);
  }
}

// ============================================================
// Onglet Alertes
// ============================================================
async function loadAlerts() {
  const container = $('alerts-container');
  try {
    const r = await fetch('/api/alerts?limit=100');
    if (!r.ok) return;
    const alerts = await r.json();

    const unacked = alerts.filter((a) => !a.acknowledged);
    const badge = $('alert-badge');
    if (unacked.length > 0) {
      badge.textContent = unacked.length;
      badge.classList.remove('hidden');
    } else {
      badge.classList.add('hidden');
    }

    if (alerts.length === 0) {
      container.innerHTML = '<p class="empty-msg">Aucune alerte enregistrée.</p>';
      return;
    }

    container.innerHTML = alerts.map((a) => `
      <div class="alert-item level-${a.level} ${a.acknowledged ? 'acknowledged' : ''}">
        <span class="alert-level">${a.level}</span>
        <div class="alert-body">
          <div class="alert-time">${formatDateTime(a.timestamp)}</div>
          <div class="alert-msg">${escapeHtml(a.message)}</div>
        </div>
        ${!a.acknowledged ? `<button class="btn-ack" onclick="ackAlert(${a.id}, this)">Acquitter</button>` : ''}
      </div>
    `).join('');
  } catch (e) {
    container.innerHTML = '<p class="empty-msg">Erreur de chargement.</p>';
  }
}

async function ackAlert(id, btn) {
  try {
    const r = await fetch(`/api/alerts/${id}/acknowledge`, { method: 'POST' });
    if (r.ok) {
      btn.closest('.alert-item').classList.add('acknowledged');
      btn.remove();
      loadAlerts();
    }
  } catch (e) {
    console.warn('ackAlert:', e);
  }
}
window.ackAlert = ackAlert;

function escapeHtml(str) {
  return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ============================================================
// Onglet Info UPS
// ============================================================
async function loadInfo() {
  try {
    const r = await fetch('/api/info');
    if (!r.ok) return;
    const info = await r.json();

    $('i-manufacturer').textContent  = info.manufacturer  || '—';
    $('i-model').textContent         = info.model         || '—';
    $('i-serial').textContent        = info.serial_number || '—';
    $('i-firmware').textContent      = info.firmware      || '—';
    $('i-rated-power').textContent   = info.rated_power_watts ? `${info.rated_power_watts} W` : '—';
    $('i-bat-replaced').textContent  = info.battery_last_replaced || '—';

    // Config (injectée côté serveur dans les meta ou via endpoint dédié)
    $('i-snmp-auth').textContent  = 'SNMPv3 / SHA';
    $('i-snmp-priv').textContent  = 'AES-128';
  } catch (e) {
    console.warn('loadInfo:', e);
  }
}

// ============================================================
// Bootstrap de l'application
// ============================================================
async function boot() {
  const isAuth = await checkAuth();

  if (!isAuth) {
    // Affiche le formulaire de login
    $('login-screen').classList.remove('hidden');
    $('login-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const errEl = $('login-error');
      errEl.classList.add('hidden');
      try {
        await login($('login-user').value, $('login-pass').value);
        location.reload();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
    return;
  }

  // Affiche l'app
  $('app').classList.remove('hidden');

  // Init tabs
  initTabs();

  // Init graphiques live
  initCharts();

  // Charge l'historique initial pour les graphiques
  await loadInitialHistory();

  // Charge les infos UPS dans le header
  try {
    const r = await fetch('/api/info');
    if (r.ok) {
      const info = await r.json();
      if (info.model) $('ups-model').textContent = info.model;
      if (info.serial_number) $('footer-serial').textContent = `S/N: ${info.serial_number}`;
    }
  } catch {}

  // Charge le statut initial
  try {
    const r = await fetch('/api/status');
    if (r.ok) {
      const d = await r.json();
      updateDashboard(d);
    }
  } catch {}

  // Charge les alertes pour le badge
  loadAlerts();

  // Bouton déconnexion
  $('btn-logout').addEventListener('click', logout);

  // Bouton historique
  $('btn-refresh-history').addEventListener('click', loadHistory);

  // WebSocket temps réel
  connectWebSocket();
}

document.addEventListener('DOMContentLoaded', boot);
