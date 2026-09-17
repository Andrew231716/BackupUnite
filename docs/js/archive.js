(function (root) {
  "use strict";

  const DATABASE_NAME = "userData.db";
  const MANIFEST_NAME = "manifest.json";

  function hexFromBuffer(buffer, pad) {
    const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
    let out = "";
    for (let i = 0; i < bytes.length; i += 1) {
      const part = bytes[i].toString(16);
      out += pad ? part.padStart(2, "0") : part;
    }
    return out;
  }

  async function sha256Bytes(data) {
    return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  }

  async function sha256Hex(data) {
    return hexFromBuffer(await sha256Bytes(data), true);
  }

  async function jwMediaHash(data) {
    return hexFromBuffer(await sha256Bytes(data), false);
  }

  function parseDate(value) {
    if (!value) return new Date(-8640000000000000);
    const parsed = new Date(value);
    if (!Number.isNaN(parsed.getTime())) return parsed;
    return new Date(-8640000000000000);
  }

  function isoNow() {
    return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  }

  function pad(n) {
    return String(n).padStart(2, "0");
  }

  function outputStamp(date) {
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) +
      "_" + pad(date.getHours()) + "-" + pad(date.getMinutes()) + "-" + pad(date.getSeconds());
  }

  async function extract(buffer) {
    const zip = await JSZip.loadAsync(buffer);
    const files = {};
    const names = Object.keys(zip.files).filter(function (name) {
      return !zip.files[name].dir && !name.split("/").pop().startsWith(".");
    });
    for (let i = 0; i < names.length; i += 1) {
      files[names[i]] = await zip.files[names[i]].async("uint8array");
    }
    const manifestEntry = files[MANIFEST_NAME];
    if (!manifestEntry) throw new Error("Archivio non valido: manifest.json mancante");
    let manifest;
    try {
      manifest = JSON.parse(new TextDecoder().decode(manifestEntry));
    } catch (error) {
      throw new Error("Archivio non valido: manifest.json illeggibile");
    }
    const backup = manifest.userDataBackup || {};
    const schema = backup.schemaVersion == null ? -1 : Number(backup.schemaVersion);
    if (schema !== 16) throw new Error("Schema " + schema + " non supportato; serve lo schema 16.");
    const storedDatabaseName = backup.databaseName || DATABASE_NAME;
    const database = files[storedDatabaseName];
    if (!database) throw new Error("Archivio non valido: database " + storedDatabaseName + " mancante");
    const assetNames = Object.keys(files).filter(function (name) {
      return name !== MANIFEST_NAME && name !== storedDatabaseName;
    }).sort();
    return {
      files: files,
      database: database,
      databaseName: storedDatabaseName,
      manifest: manifest,
      assetNames: assetNames
    };
  }

  async function writeManifest(source, outputName, databaseBytes) {
    const now = isoNow();
    const manifest = {
      version: source.version == null ? 1 : source.version,
      name: outputName,
      type: source.type == null ? 0 : source.type,
      userDataBackup: {
        lastModifiedDate: now,
        hash: await sha256Hex(databaseBytes),
        schemaVersion: 16,
        deviceName: "Backup Unite",
        databaseName: DATABASE_NAME
      },
      creationDate: now
    };
    return new TextEncoder().encode(JSON.stringify(manifest));
  }

  async function createArchive(files) {
    const zip = new JSZip();
    Object.keys(files).forEach(function (name) {
      zip.file(name, files[name]);
    });
    return zip.generateAsync({ type: "uint8array", compression: "DEFLATE" });
  }

  root.BackupUniteArchive = {
    DATABASE_NAME: DATABASE_NAME,
    MANIFEST_NAME: MANIFEST_NAME,
    sha256Hex: sha256Hex,
    jwMediaHash: jwMediaHash,
    parseDate: parseDate,
    isoNow: isoNow,
    outputStamp: outputStamp,
    extract: extract,
    writeManifest: writeManifest,
    createArchive: createArchive
  };
})(typeof self !== "undefined" ? self : window);
