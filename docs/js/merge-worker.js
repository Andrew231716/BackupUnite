importScripts("../vendor/sql-wasm.js", "../vendor/jszip.min.js", "./sqlite.js", "./archive.js", "./merge-engine.js");

let sqlReady = null;

async function ensureSql() {
  if (!sqlReady) {
    sqlReady = initSqlJs({
      locateFile: function (file) {
        return "../vendor/" + file;
      }
    }).then(function (SQLModule) {
      self.SQL = SQLModule;
      return SQLModule;
    });
  }
  return sqlReady;
}

self.onmessage = async function (event) {
  const data = event.data || {};
  try {
    await ensureSql();
    if (data.type === "analyze") {
      const analysis = await BackupUniteEngine.analyze(data.left, data.right, data.highlightMode);
      self.postMessage({ id: data.id, ok: true, analysis: analysis });
    } else if (data.type === "merge") {
      const summary = await BackupUniteEngine.merge(data.left, data.right, data.resolutions, data.highlightMode);
      self.postMessage({ id: data.id, ok: true, summary: summary });
    } else {
      throw new Error("Operazione sconosciuta");
    }
  } catch (error) {
    self.postMessage({ id: data.id, ok: false, error: error && error.message ? error.message : String(error) });
  }
};
