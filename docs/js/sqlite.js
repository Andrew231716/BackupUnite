(function (root) {
  "use strict";

  function integer(n) {
    return { k: "i", v: Number(n) };
  }
  function real(n) {
    return { k: "r", v: Number(n) };
  }
  function text(s) {
    return { k: "t", v: String(s) };
  }
  function blob(bytes) {
    return { k: "b", v: bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || []) };
  }
  function nullValue() {
    return { k: "n", v: null };
  }

  function bytesToBase64(bytes) {
    let binary = "";
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
  }

  function stable(value) {
    if (!value || value.k === "n") return "n:";
    if (value.k === "i") return "i:" + value.v;
    if (value.k === "r") return "r:" + value.v;
    if (value.k === "t") return "t:" + value.v;
    if (value.k === "b") return "b:" + bytesToBase64(value.v);
    return "n:";
  }

  function valuesEqual(a, b) {
    if ((!a || a.k === "n") && (!b || b.k === "n")) return true;
    if (!a || !b) return false;
    if (a.k !== b.k) return false;
    if (a.k === "b") {
      if (a.v.length !== b.v.length) return false;
      for (let i = 0; i < a.v.length; i += 1) {
        if (a.v[i] !== b.v[i]) return false;
      }
      return true;
    }
    return a.v === b.v;
  }

  function optionalInt(row, key) {
    const value = row[key];
    return value && value.k === "i" ? value.v : null;
  }

  function optionalText(row, key) {
    const value = row[key];
    return value && value.k === "t" ? value.v : null;
  }

  function requireInt(row, key) {
    const value = optionalInt(row, key);
    if (value === null) throw new Error("Riga database non valida: " + key + " is not an integer");
    return value;
  }

  function requireText(row, key) {
    const value = optionalText(row, key);
    if (value === null) throw new Error("Riga database non valida: " + key + " is not text");
    return value;
  }

  function cloneRow(row) {
    const copy = {};
    Object.keys(row).forEach(function (key) {
      const value = row[key];
      if (!value || value.k === "n") copy[key] = nullValue();
      else if (value.k === "b") copy[key] = blob(value.v.slice());
      else copy[key] = { k: value.k, v: value.v };
    });
    return copy;
  }

  function declaredKind(typeName) {
    const type = String(typeName || "").toUpperCase();
    if (type.indexOf("INT") !== -1) return "i";
    if (type.indexOf("CHAR") !== -1 || type.indexOf("CLOB") !== -1 || type.indexOf("TEXT") !== -1) return "t";
    if (type.indexOf("BLOB") !== -1 || type === "") return "b";
    if (type.indexOf("REAL") !== -1 || type.indexOf("FLOA") !== -1 || type.indexOf("DOUB") !== -1) return "r";
    return "t";
  }

  function wrapRaw(raw, kind) {
    if (raw === null || raw === undefined) return nullValue();
    if (raw instanceof Uint8Array) return blob(raw);
    if (typeof raw === "string") return text(raw);
    if (typeof raw === "number") {
      if (kind === "r" || (!Number.isInteger(raw) && kind !== "i")) return real(raw);
      return integer(raw);
    }
    if (typeof raw === "bigint") return integer(Number(raw));
    return text(String(raw));
  }

  function toBind(value) {
    if (!value || value.k === "n") return null;
    if (value.k === "b") return value.v;
    return value.v;
  }

  function quote(identifier) {
    return '"' + String(identifier).replace(/"/g, '""') + '"';
  }

  function SQLiteDatabase(data, readOnly) {
    this.readOnly = !!readOnly;
    this.db = new SQL.Database(data instanceof Uint8Array ? data : new Uint8Array(data || []));
    this.columnKinds = {};
  }

  SQLiteDatabase.prototype.close = function () {
    if (this.db) {
      this.db.close();
      this.db = null;
    }
  };

  SQLiteDatabase.prototype.execute = function (sql, values) {
    const stmt = this.db.prepare(sql);
    try {
      stmt.bind((values || []).map(toBind));
      stmt.step();
    } finally {
      stmt.free();
    }
  };

  SQLiteDatabase.prototype.query = function (sql, values) {
    const stmt = this.db.prepare(sql);
    const rows = [];
    try {
      if (values && values.length) stmt.bind(values.map(toBind));
      const names = stmt.getColumnNames();
      while (stmt.step()) {
        const raw = stmt.get();
        const row = {};
        for (let i = 0; i < names.length; i += 1) {
          row[names[i]] = wrapRaw(raw[i], null);
        }
        rows.push(row);
      }
    } finally {
      stmt.free();
    }
    return rows;
  };

  SQLiteDatabase.prototype.tableKinds = function (table) {
    if (this.columnKinds[table]) return this.columnKinds[table];
    const info = this.query("PRAGMA table_info(" + quote(table) + ")");
    const kinds = {};
    info.forEach(function (row) {
      const name = optionalText(row, "name") || optionalText(row, "Name");
      if (name) kinds[name] = declaredKind(optionalText(row, "type") || optionalText(row, "Type"));
    });
    this.columnKinds[table] = kinds;
    return kinds;
  };

  SQLiteDatabase.prototype.allRows = function (table) {
    const kinds = this.tableKinds(table);
    const stmt = this.db.prepare("SELECT * FROM " + quote(table));
    const rows = [];
    try {
      const names = stmt.getColumnNames();
      while (stmt.step()) {
        const raw = stmt.get();
        const row = {};
        for (let i = 0; i < names.length; i += 1) {
          row[names[i]] = wrapRaw(raw[i], kinds[names[i]]);
        }
        rows.push(row);
      }
    } finally {
      stmt.free();
    }
    return rows;
  };

  SQLiteDatabase.prototype.insert = function (rows, table) {
    if (!rows.length) return;
    const columns = Object.keys(rows[0]).sort();
    const placeholders = columns.map(function () { return "?"; }).join(",");
    const sql = "INSERT INTO " + quote(table) + " (" + columns.map(quote).join(",") + ") VALUES (" + placeholders + ")";
    const stmt = this.db.prepare(sql);
    try {
      rows.forEach(function (row) {
        stmt.bind(columns.map(function (column) { return toBind(row[column] || nullValue()); }));
        stmt.step();
        stmt.reset();
      });
    } finally {
      stmt.free();
    }
  };

  SQLiteDatabase.prototype.export = function () {
    return this.db.export();
  };

  root.BackupUniteSQLite = {
    integer: integer,
    real: real,
    text: text,
    blob: blob,
    nullValue: nullValue,
    stable: stable,
    valuesEqual: valuesEqual,
    optionalInt: optionalInt,
    optionalText: optionalText,
    requireInt: requireInt,
    requireText: requireText,
    cloneRow: cloneRow,
    quote: quote,
    SQLiteDatabase: SQLiteDatabase
  };
})(typeof self !== "undefined" ? self : window);
