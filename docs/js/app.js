const KIND_META = {
  bookmark: { title: "Segnalibri", singular: "Conflitto segnalibro" },
  marking: { title: "Evidenziazioni", singular: "Conflitto evidenziazione" },
  note: { title: "Note", singular: "Conflitto nota" },
  inputField: { title: "Campi compilati", singular: "Conflitto campo compilato" }
};

const HIGHLIGHT_COPY = {
  both: "Unisce le sottolineature dei due backup e ti mostra le eventuali collisioni.",
  leftOnly: "Usa soltanto le sottolineature del primo backup selezionato.",
  rightOnly: "Usa soltanto le sottolineature del secondo backup selezionato."
};

const state = {
  files: [],
  highlightMode: "both",
  busy: false,
  status: "",
  analysis: null,
  resolutions: {},
  summary: null,
  error: "",
  storageMessage: "",
  saved: [],
  resolverOpen: false,
  resolverIndex: 0,
  bulkOpen: false
};

let worker = null;
let requestId = 0;
const pending = new Map();

function callWorker(payload, transfer) {
  if (!worker) {
    worker = new Worker("js/merge-worker.js");
    worker.onmessage = function (event) {
      const message = event.data || {};
      const deferred = pending.get(message.id);
      if (!deferred) return;
      pending.delete(message.id);
      if (message.ok) deferred.resolve(message);
      else deferred.reject(new Error(message.error || "Operazione non riuscita"));
    };
    worker.onerror = function (event) {
      state.error = event.message || "Il motore di merge non è disponibile.";
      render();
    };
  }
  const id = ++requestId;
  return new Promise(function (resolve, reject) {
    pending.set(id, { resolve: resolve, reject: reject });
    worker.postMessage(Object.assign({ id: id }, payload), transfer || []);
  });
}

function $(id) {
  return document.getElementById(id);
}

function escapeHtml(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatDate(ms) {
  return new Date(ms).toLocaleString("it-IT", { dateStyle: "medium", timeStyle: "short" });
}

async function refreshSaved() {
  state.saved = await BackupUniteStorage.list();
}

function isJwLibraryName(name) {
  return /\.jwlibrary$/i.test(name || "");
}

function selectedNames() {
  if (!state.files.length) {
    return '<div class="file-box">Nessun backup selezionato<br><span class="caption">Puoi sceglierli insieme oppure uno alla volta.</span></div>';
  }
  return '<div class="file-box">' + state.files.map(function (file, index) {
    return '<div class="file-item"><strong>' + (index + 1) + '</strong><span>' + escapeHtml(file.name) + '</span><span class="ok">✓</span></div>';
  }).join("") + "</div>";
}

function pickButtonLabel() {
  if (!state.files.length) return "Scegli i backup";
  if (state.files.length === 1) return "Aggiungi il secondo backup";
  return "Cambia selezione";
}

function primaryLabel() {
  if (!state.analysis) return "Analizza conflitti";
  const unresolved = state.analysis.conflicts.filter(function (item) { return !state.resolutions[item.id]; }).length;
  if (unresolved > 0) return "Risolvi " + unresolved + " conflitti";
  return "Crea e verifica il backup";
}

function conflictSummary() {
  if (!state.analysis || !state.analysis.conflicts.length) return "";
  const grouped = {};
  state.analysis.conflicts.forEach(function (item) {
    grouped[item.kind] = (grouped[item.kind] || 0) + 1;
  });
  const unresolved = state.analysis.conflicts.filter(function (item) { return !state.resolutions[item.id]; }).length;
  const rows = Object.keys(KIND_META).map(function (kind) {
    if (!grouped[kind]) return "";
    return '<div class="row space"><span>' + KIND_META[kind].title + '</span><strong>' + grouped[kind] + '</strong></div>';
  }).join("");
  return (
    '<section class="card">' +
      '<h2>Collisioni trovate <span>' + state.analysis.conflicts.length + '</span></h2>' +
      rows +
      '<p class="' + (unresolved ? "error" : "ok-line") + '">' +
        (unresolved ? "Mancano " + unresolved + " scelte" : "Tutte le scelte sono state confermate") +
      "</p>" +
      '<button class="secondary full" data-action="open-resolver">' + (unresolved ? "Scegli cosa conservare" : "Rivedi le scelte") + "</button>" +
    "</section>"
  );
}

function resultCard() {
  const summary = state.summary;
  if (!summary) return "";
  const resolved = summary.bookmarkConflicts + summary.markingConflicts + summary.noteConflicts + summary.inputFieldConflicts;
  return (
    '<section class="card">' +
      '<h2 class="ok-line">Backup verificato <span class="caption">schema 16</span></h2>' +
      '<div class="grid">' +
        stat("Note", summary.notes) +
        stat("Evidenziazioni", summary.highlights) +
        stat("Segnalibri", summary.bookmarks) +
        stat("Playlist", summary.playlists) +
        stat("Elementi playlist", summary.playlistItems) +
        stat("Media", summary.media) +
      "</div>" +
      '<p class="caption">Integrità SQLite OK · 0 collegamenti non validi · media e miniature presenti</p>' +
      '<p class="caption">Sottolineature: ' + escapeHtml(highlightTitle(state.highlightMode).toLowerCase()) + "</p>" +
      (resolved ? '<p class="caption">Sono state applicate le tue scelte a ' + resolved + " conflitti: " +
        summary.bookmarkConflicts + " segnalibri, " + summary.markingConflicts + " evidenziazioni, " +
        summary.noteConflicts + " note e " + summary.inputFieldConflicts + " campi.</p>" : "") +
      '<div class="stack" style="margin-top:12px">' +
        '<button class="success full" data-action="download-result">Scarica il backup unito</button>' +
        (state.analysis && state.analysis.conflicts.length ? '<button class="secondary full" data-action="open-resolver">Modifica le scelte e ricrea</button>' : "") +
        '<button class="secondary full" data-action="reset">Unisci altri due backup</button>' +
        '<div class="mono">' + escapeHtml(summary.filename) + "</div>" +
      "</div>" +
    "</section>"
  );
}

function stat(label, value) {
  return '<div class="stat"><div><strong>' + value + "</strong><div class=\"caption\">" + label + "</div></div></div>";
}

function savedCard() {
  const items = state.saved.slice(0, 8).map(function (item) {
    return (
      '<div class="backup-item">' +
        '<div class="row space">' +
          "<div><strong>" + escapeHtml(item.name) + "</strong><div class=\"caption\">" +
            formatDate(item.modified) + " · " + BackupUniteStorage.formatSize(item.size) +
          "</div></div>" +
          '<div class="row">' +
            '<button class="secondary" data-action="download-saved" data-id="' + item.id + '">Scarica</button>' +
            '<button class="secondary" data-action="rename-saved" data-id="' + item.id + '">Rinomina</button>' +
          "</div>" +
        "</div>" +
      "</div>"
    );
  }).join("");
  return (
    '<section class="card">' +
      "<h2>I tuoi backup uniti <span>" + state.saved.length + "</span></h2>" +
      '<p class="muted">Restano in questo browser. Puoi scaricarli e aprirli in JW Library.</p>' +
      (items || '<div class="file-box">Non hai ancora creato backup</div>') +
      (state.storageMessage ? '<p class="ok-line">' + escapeHtml(state.storageMessage) + "</p>" : "") +
    "</section>"
  );
}

function highlightTitle(mode) {
  return mode === "leftOnly" ? "1° backup" : mode === "rightOnly" ? "2° backup" : "Entrambi";
}

function resolverSheet() {
  if (!state.resolverOpen || !state.analysis) return "";
  const conflicts = state.analysis.conflicts;
  const conflict = conflicts[state.resolverIndex];
  const resolvedCount = conflicts.filter(function (item) { return state.resolutions[item.id]; }).length;
  const selected = state.resolutions[conflict.id];
  const percent = conflicts.length ? Math.round((resolvedCount / conflicts.length) * 100) : 0;
  function choice(side, version, filename) {
    const isSelected = selected === side;
    const recommended = conflict.recommended === side;
    return (
      '<button class="choice ' + (isSelected ? "selected" : "") + '" data-action="choose" data-side="' + side + '">' +
        '<div class="row space">' +
          "<div><div class=\"caption\">" + (side === "left" ? "PRIMO BACKUP" : "SECONDO BACKUP") + "</div><div class=\"small\">" + escapeHtml(filename) + "</div></div>" +
          (recommended ? '<span class="badge">CONSIGLIATO</span>' : "") +
        "</div>" +
        "<h3>" + escapeHtml(version.title) + "</h3>" +
        (version.preview ? "<p>" + escapeHtml(version.preview) + "</p>" : "") +
        version.details.map(function (detail) { return '<div class="caption">' + escapeHtml(detail) + "</div>"; }).join("") +
      "</button>"
    );
  }
  return (
    '<div class="overlay"><div class="sheet">' +
      '<div class="row space"><strong>' + KIND_META[conflict.kind].singular + '</strong><button class="secondary" data-action="close-resolver">Chiudi</button></div>' +
      '<div class="progress" style="margin:12px 0"><span style="width:' + percent + '%"></span></div>' +
      '<p class="caption">' + (state.resolverIndex + 1) + " di " + conflicts.length + " · " + resolvedCount + " risolti</p>" +
      '<div class="context"><div class="caption">Dove si trova</div><div>' + escapeHtml(conflict.context) + "</div></div>" +
      choice("left", conflict.left, state.analysis.leftName) +
      choice("right", conflict.right, state.analysis.rightName) +
      (conflict.kind === "note"
        ? '<button class="choice ' + (selected === "both" ? "selected" : "") + '" data-action="choose" data-side="both"><div class="caption">CONSERVA ENTRAMBE</div><h3>Mantieni tutti e due i testi</h3><p class="muted">La seconda nota riceve un nuovo identificatore e conserva contenuto, posizione e collegamenti.</p></button>'
        : "") +
      '<button class="secondary full" data-action="toggle-bulk">Applica la stessa scelta a più conflitti</button>' +
      (state.bulkOpen ? bulkMenu(conflict) : "") +
      '<div class="actions" style="margin-top:12px">' +
        '<button class="secondary" data-action="prev-conflict" ' + (state.resolverIndex === 0 ? "disabled" : "") + ">Indietro</button>" +
        '<button class="primary" data-action="continue-conflict" ' + (!selected ? "disabled" : "") + ">" +
          (resolvedCount === conflicts.length ? "Conferma e crea" : "Continua") +
        "</button>" +
      "</div>" +
    "</div></div>"
  );
}

function bulkMenu(conflict) {
  return (
    '<div class="menu">' +
      '<button class="secondary" data-action="bulk" data-scope="kind" data-side="left">Usa sempre il primo backup per ' + KIND_META[conflict.kind].title.toLowerCase() + "</button>" +
      '<button class="secondary" data-action="bulk" data-scope="kind" data-side="right">Usa sempre il secondo backup per ' + KIND_META[conflict.kind].title.toLowerCase() + "</button>" +
      (conflict.kind === "note" ? '<button class="secondary" data-action="bulk" data-scope="kind" data-side="both">Conserva entrambe le note</button>' : "") +
      '<button class="secondary" data-action="bulk" data-scope="kind" data-side="recommended">Usa sempre la scelta consigliata</button>' +
      '<button class="secondary" data-action="bulk" data-scope="all" data-side="left">Usa il primo backup per tutti</button>' +
      '<button class="secondary" data-action="bulk" data-scope="all" data-side="right">Usa il secondo backup per tutti</button>' +
      '<button class="secondary" data-action="bulk" data-scope="all" data-side="recommended">Usa tutte le scelte consigliate</button>' +
    "</div>"
  );
}

function render() {
  $("app").innerHTML =
    '<header class="hero">' +
      '<div class="logo">☁︎</div>' +
      "<h1>Unisci i tuoi backup</h1>" +
      "<p>Carica due file .jwlibrary, scegli cosa conservare in caso di collisioni e crea un backup verificato per JW Library.</p>" +
    "</header>" +
    '<div class="stack">' +
      '<section class="card">' +
        "<h2>Nuovo merge</h2>" +
        '<p class="muted">Scegli due file .jwlibrary. Su iPhone, se i file sembrano non selezionabili, apri «Sfoglia» e sceglili uno alla volta: il filtro del sistema non riconosce sempre l’estensione.</p>' +
        selectedNames() +
        '<button class="secondary full" data-action="pick" ' + (state.busy ? "disabled" : "") + ">" +
          pickButtonLabel() +
        "</button>" +
        (state.files.length ? '<button class="secondary full" style="margin-top:8px" data-action="clear-files" ' + (state.busy ? "disabled" : "") + ">Rimuovi selezione</button>" : "") +
        '<div class="context" style="margin-top:12px">' +
          "<strong>Sottolineature da usare</strong>" +
          '<div class="segmented" style="margin:10px 0">' +
            '<button class="' + (state.highlightMode === "both" ? "active" : "") + '" data-action="highlight" data-mode="both" ' + (state.busy ? "disabled" : "") + ">Entrambi</button>" +
            '<button class="' + (state.highlightMode === "leftOnly" ? "active" : "") + '" data-action="highlight" data-mode="leftOnly" ' + (state.busy ? "disabled" : "") + ">1° backup</button>" +
            '<button class="' + (state.highlightMode === "rightOnly" ? "active" : "") + '" data-action="highlight" data-mode="rightOnly" ' + (state.busy ? "disabled" : "") + ">2° backup</button>" +
          "</div>" +
          '<p class="caption">' + HIGHLIGHT_COPY[state.highlightMode] + "</p>" +
        "</div>" +
        '<button class="primary full" style="margin-top:14px" data-action="primary" ' +
          (state.files.length !== 2 || state.busy || state.summary ? "disabled" : "") + ">" + primaryLabel() + "</button>" +
        (state.busy ? '<div class="busy"><div>⏳</div><div><strong>' + escapeHtml(state.status) + "</strong><div class=\"caption\">Non chiudere la pagina; il controllo finale può richiedere qualche minuto.</div></div></div>" : "") +
        (state.error ? '<p class="error">' + escapeHtml(state.error) + "</p>" : "") +
      "</section>" +
      conflictSummary() +
      resultCard() +
      savedCard() +
      '<p class="note">Prima di eliminare gli originali, controlla in JW Library alcune note, evidenziazioni, segnalibri e ogni playlist.</p>' +
    "</div>" +
    resolverSheet();
}

function receiveFiles(fileList) {
  const incoming = Array.from(fileList || []);
  if (!incoming.length) return;

  const invalid = incoming.find(function (file) { return !isJwLibraryName(file.name); });
  if (invalid) {
    state.error = "Il file «" + invalid.name + "» non è un backup .jwlibrary. Seleziona solo file con quella estensione.";
    render();
    return;
  }

  let next = [];
  if (incoming.length >= 2) {
    next = incoming.slice(0, 2);
  } else if (state.files.length === 1 && incoming.length === 1) {
    next = [state.files[0], incoming[0]];
  } else {
    next = incoming.slice(0, 1);
  }

  state.files = next;
  state.analysis = null;
  state.resolutions = {};
  state.summary = null;
  state.error = "";
  state.storageMessage = next.length === 1
    ? "Primo backup pronto. Tocca di nuovo per aggiungere il secondo."
    : "";
  render();
}

function openFilePicker() {
  const input = $("file-input");
  input.value = "";
  input.click();
}

async function buffersFromFiles() {
  const left = state.files[0];
  const right = state.files[1];
  return {
    left: { name: left.name, buffer: new Uint8Array(await left.arrayBuffer()) },
    right: { name: right.name, buffer: new Uint8Array(await right.arrayBuffer()) }
  };
}

async function startAnalysis() {
  state.busy = true;
  state.status = "Analisi delle collisioni…";
  state.analysis = null;
  state.resolutions = {};
  state.summary = null;
  state.error = "";
  render();
  try {
    const files = await buffersFromFiles();
    const result = await callWorker({
      type: "analyze",
      left: files.left,
      right: files.right,
      highlightMode: state.highlightMode
    });
    state.analysis = result.analysis;
    state.busy = false;
    if (!state.analysis.conflicts.length) {
      await startFinalMerge();
    } else {
      state.resolverOpen = true;
      state.resolverIndex = 0;
      render();
    }
  } catch (error) {
    state.busy = false;
    state.error = error.message;
    render();
  }
}

async function startFinalMerge() {
  if (state.analysis && state.analysis.conflicts.some(function (item) { return !state.resolutions[item.id]; })) {
    state.resolverOpen = true;
    render();
    return;
  }
  state.busy = true;
  state.status = "Creazione e verifica del backup…";
  state.summary = null;
  state.error = "";
  state.resolverOpen = false;
  render();
  try {
    const files = await buffersFromFiles();
    const result = await callWorker({
      type: "merge",
      left: files.left,
      right: files.right,
      resolutions: state.resolutions,
      highlightMode: state.highlightMode
    });
    const summary = result.summary;
    const bytes = summary.bytes instanceof Uint8Array ? summary.bytes : new Uint8Array(summary.bytes);
    const record = {
      id: crypto.randomUUID(),
      name: summary.filename,
      modified: Date.now(),
      size: bytes.byteLength,
      bytes: bytes
    };
    await BackupUniteStorage.save(record);
    await refreshSaved();
    state.summary = Object.assign({}, summary, { id: record.id, bytes: bytes });
    state.storageMessage = "Backup conservato nell’archivio del browser.";
    state.busy = false;
    render();
  } catch (error) {
    state.busy = false;
    state.error = error.message;
    render();
  }
}

function downloadBytes(name, bytes) {
  const blob = new Blob([bytes], { type: "application/zip" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
}

function applyBulk(scope, side) {
  state.analysis.conflicts.forEach(function (item) {
    if (scope === "kind" && item.kind !== state.analysis.conflicts[state.resolverIndex].kind) return;
    state.resolutions[item.id] = side === "recommended" ? (item.kind === "note" && side === "both" ? "both" : item.recommended) : side;
  });
}

document.addEventListener("click", async function (event) {
  const button = event.target.closest("[data-action]");
  if (!button || button.disabled) return;
  const action = button.getAttribute("data-action");
  if (action === "pick") openFilePicker();
  if (action === "clear-files") {
    state.files = [];
    state.analysis = null;
    state.resolutions = {};
    state.summary = null;
    state.error = "";
    state.storageMessage = "";
    $("file-input").value = "";
    render();
  }
  if (action === "highlight") {
    state.highlightMode = button.getAttribute("data-mode");
    state.analysis = null;
    state.resolutions = {};
    state.summary = null;
    state.error = "";
    render();
  }
  if (action === "primary") {
    if (!state.analysis) startAnalysis();
    else if (state.analysis.conflicts.some(function (item) { return !state.resolutions[item.id]; })) {
      state.resolverOpen = true;
      render();
    } else startFinalMerge();
  }
  if (action === "open-resolver") { state.resolverOpen = true; render(); }
  if (action === "close-resolver") { state.resolverOpen = false; render(); }
  if (action === "choose") {
    state.resolutions[state.analysis.conflicts[state.resolverIndex].id] = button.getAttribute("data-side");
    render();
  }
  if (action === "toggle-bulk") { state.bulkOpen = !state.bulkOpen; render(); }
  if (action === "bulk") {
    applyBulk(button.getAttribute("data-scope"), button.getAttribute("data-side"));
    state.bulkOpen = false;
    render();
  }
  if (action === "prev-conflict") {
    state.resolverIndex = Math.max(0, state.resolverIndex - 1);
    render();
  }
  if (action === "continue-conflict") {
    const conflicts = state.analysis.conflicts;
    const resolvedCount = conflicts.filter(function (item) { return state.resolutions[item.id]; }).length;
    if (resolvedCount === conflicts.length) {
      startFinalMerge();
      return;
    }
    const next = conflicts.findIndex(function (item, index) {
      return index > state.resolverIndex && !state.resolutions[item.id];
    });
    const first = conflicts.findIndex(function (item) { return !state.resolutions[item.id]; });
    state.resolverIndex = next >= 0 ? next : first;
    render();
  }
  if (action === "download-result" && state.summary) downloadBytes(state.summary.filename, state.summary.bytes);
  if (action === "reset") {
    state.files = [];
    state.analysis = null;
    state.resolutions = {};
    state.highlightMode = "both";
    state.summary = null;
    state.error = "";
    state.storageMessage = "";
    $("file-input").value = "";
    render();
  }
  if (action === "download-saved") {
    const item = state.saved.find(function (entry) { return entry.id === button.getAttribute("data-id"); });
    if (item) downloadBytes(item.name, item.bytes);
  }
  if (action === "rename-saved") {
    const item = state.saved.find(function (entry) { return entry.id === button.getAttribute("data-id"); });
    if (!item) return;
    const next = prompt("Nome del backup", item.name.replace(/\.jwlibrary$/i, ""));
    if (!next) return;
    const cleaned = next.replace(/\.jwlibrary$/i, "").replace(/[/\\:\0]/g, "-").trim();
    if (!cleaned) {
      state.error = "Inserisci un nome valido per il backup.";
      render();
      return;
    }
    item.name = cleaned + ".jwlibrary";
    await BackupUniteStorage.save(item);
    if (state.summary && state.summary.id === item.id) state.summary.filename = item.name;
    state.storageMessage = "Backup rinominato.";
    await refreshSaved();
    render();
  }
});

$("file-input").addEventListener("change", function (event) {
  receiveFiles(event.target.files);
});

refreshSaved().then(render).catch(function (error) {
  state.error = error.message;
  render();
});
