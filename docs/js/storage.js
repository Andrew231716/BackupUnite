(function (root) {
  "use strict";

  const DB_NAME = "backup-unite";
  const STORE = "merged";

  function openDb() {
    return new Promise(function (resolve, reject) {
      const request = indexedDB.open(DB_NAME, 1);
      request.onupgradeneeded = function () {
        const db = request.result;
        if (!db.objectStoreNames.contains(STORE)) {
          db.createObjectStore(STORE, { keyPath: "id" });
        }
      };
      request.onsuccess = function () { resolve(request.result); };
      request.onerror = function () { reject(request.error); };
    });
  }

  async function withStore(mode, fn) {
    const db = await openDb();
    return new Promise(function (resolve, reject) {
      const tx = db.transaction(STORE, mode);
      const store = tx.objectStore(STORE);
      Promise.resolve(fn(store)).then(function (result) {
        tx.oncomplete = function () {
          db.close();
          resolve(result);
        };
        tx.onerror = function () {
          db.close();
          reject(tx.error);
        };
      }).catch(function (error) {
        db.close();
        reject(error);
      });
    });
  }

  function list() {
    return withStore("readonly", function (store) {
      return new Promise(function (resolve, reject) {
        const request = store.getAll();
        request.onsuccess = function () {
          const items = (request.result || []).sort(function (a, b) { return b.modified - a.modified; });
          resolve(items);
        };
        request.onerror = function () { reject(request.error); };
      });
    });
  }

  function save(record) {
    return withStore("readwrite", function (store) {
      store.put(record);
      return record;
    });
  }

  function remove(id) {
    return withStore("readwrite", function (store) {
      store.delete(id);
    });
  }

  function formatSize(bytes) {
    if (bytes < 1024) return bytes + " byte";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1).replace(".", ",") + " KB";
    return (bytes / (1024 * 1024)).toFixed(1).replace(".", ",") + " MB";
  }

  root.BackupUniteStorage = {
    list: list,
    save: save,
    remove: remove,
    formatSize: formatSize
  };
})(typeof self !== "undefined" ? self : window);
