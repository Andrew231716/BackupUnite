(function (root) {
  "use strict";

  const S = root.BackupUniteSQLite;
  const A = root.BackupUniteArchive;

  const TABLES = [
    "Location", "UserMark", "Note", "BlockRange", "Bookmark", "Tag", "TagMap",
    "InputField", "IndependentMedia", "PlaylistItemAccuracy", "PlaylistItem",
    "PlaylistItemIndependentMediaMap", "PlaylistItemLocationMap", "PlaylistItemMarker",
    "PlaylistItemMarkerBibleVerseMap", "PlaylistItemMarkerParagraphMap"
  ];

  const INSERT_ORDER = [
    "Location", "UserMark", "Note", "BlockRange", "Bookmark", "IndependentMedia",
    "PlaylistItemAccuracy", "PlaylistItem", "PlaylistItemIndependentMediaMap",
    "PlaylistItemLocationMap", "PlaylistItemMarker", "PlaylistItemMarkerBibleVerseMap",
    "PlaylistItemMarkerParagraphMap", "Tag", "TagMap", "InputField"
  ];

  const HIGHLIGHT_SOURCES = {
    both: ["left", "right"],
    leftOnly: ["left"],
    rightOnly: ["right"]
  };

  function engineError(kind, message) {
    const errors = {
      invalidArchive: "Archivio non valido: " + message,
      unsupportedSchema: "Schema " + message + " non supportato; serve lo schema 16.",
      sqlite: "Errore SQLite: " + message,
      missingMapping: "Rimappatura ID mancante: " + message,
      validation: "Validazione fallita: " + message
    };
    const error = new Error(errors[kind] || message);
    error.code = kind;
    return error;
  }

  function inspect(database, label) {
    const versionRow = database.query("PRAGMA user_version")[0] || {};
    const version = versionRow.user_version || Object.values(versionRow)[0];
    const versionNumber = version && version.k === "i" ? version.v : -1;
    if (versionNumber !== 16) throw engineError("unsupportedSchema", String(versionNumber));
    const integrityRow = database.query("PRAGMA integrity_check")[0] || {};
    const integrity = integrityRow.integrity_check || Object.values(integrityRow)[0];
    if (!integrity || integrity.k !== "t" || integrity.v !== "ok") {
      throw engineError("validation", label + ": controllo integrità non superato");
    }
    const foreignKeys = database.query("PRAGMA foreign_key_check");
    if (foreignKeys.length) {
      throw engineError("validation", label + ": " + foreignKeys.length + " collegamenti non validi");
    }
    const existing = {};
    database.query("SELECT name FROM sqlite_master WHERE type='table'").forEach(function (row) {
      const name = S.optionalText(row, "name");
      if (name) existing[name] = true;
    });
    const missing = TABLES.filter(function (table) { return !existing[table]; });
    if (missing.length) {
      throw engineError("validation", label + ": tabelle mancanti: " + missing.join(", "));
    }
  }

  function bytesEqual(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i += 1) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }

  function rebuildDatabase(baseBytes, rows) {
    const database = new S.SQLiteDatabase(baseBytes, false);
    try {
      database.execute("PRAGMA foreign_keys=OFF");
      const triggers = database.query("SELECT name, sql FROM sqlite_master WHERE type='trigger' AND sql IS NOT NULL");
      database.execute("BEGIN IMMEDIATE");
      try {
        triggers.forEach(function (trigger) {
          database.execute("DROP TRIGGER " + S.quote(S.requireText(trigger, "name")));
        });
        INSERT_ORDER.slice().reverse().forEach(function (table) {
          database.execute("DELETE FROM " + S.quote(table));
        });
        INSERT_ORDER.forEach(function (table) {
          database.insert(rows[table] || [], table);
        });
        database.execute("UPDATE LastModified SET LastModified=?", [S.text(A.isoNow())]);
        triggers.forEach(function (trigger) {
          database.execute(S.requireText(trigger, "sql"));
        });
        database.execute("PRAGMA user_version=16");
        database.execute("COMMIT");
      } catch (error) {
        try { database.execute("ROLLBACK"); } catch (ignored) {}
        throw error;
      }
      database.execute("PRAGMA foreign_keys=ON");
      const violations = database.query("PRAGMA foreign_key_check");
      if (violations.length) {
        throw engineError("validation", "Il risultato contiene " + violations.length + " collegamenti non validi");
      }
      const integrityRow = database.query("PRAGMA integrity_check")[0];
      const integrity = integrityRow ? Object.values(integrityRow)[0] : null;
      if (!integrity || integrity.k !== "t" || integrity.v !== "ok") {
        throw engineError("validation", "Il database prodotto non supera il controllo di integrità");
      }
      database.query("PRAGMA journal_mode=DELETE");
      return database.export();
    } finally {
      database.close();
    }
  }

  function copyAssets(left, right, pathMaps) {
    const output = {};
    [["left", left], ["right", right]].forEach(function (pair) {
      const source = pair[0];
      const backup = pair[1];
      backup.assetNames.forEach(function (oldName) {
        const targetName = (pathMaps[source] && pathMaps[source][oldName]) || oldName;
        const incoming = backup.files[oldName];
        if (!incoming) return;
        if (output[targetName]) {
          if (!bytesEqual(output[targetName], incoming) && source === "right") return;
        } else {
          output[targetName] = incoming;
        }
      });
    });
    return output;
  }

  async function validateArchive(bytes) {
    const backup = await A.extract(bytes);
    const userData = backup.manifest.userDataBackup || {};
    const expected = userData.hash;
    if (!expected) throw engineError("invalidArchive", "hash database mancante");
    const actual = await A.sha256Hex(backup.database);
    if (expected !== actual) throw engineError("validation", "Hash database non valido");
    const database = new S.SQLiteDatabase(backup.database, true);
    try {
      inspect(database, "risultato");
      const assets = {};
      backup.assetNames.forEach(function (name) { assets[name] = true; });
      const media = database.allRows("IndependentMedia");
      const mediaPaths = {};
      for (let i = 0; i < media.length; i += 1) {
        const path = S.requireText(media[i], "FilePath");
        mediaPaths[path] = true;
        if (!assets[path]) throw engineError("validation", "File multimediale mancante: " + path);
        const stored = S.optionalText(media[i], "Hash");
        const computed = await A.jwMediaHash(backup.files[path]);
        const computedPadded = await A.sha256Hex(backup.files[path]);
        if (stored !== computed && stored !== computedPadded) {
          throw engineError("validation", "Hash multimediale non valido: " + path);
        }
      }
      database.allRows("PlaylistItem").forEach(function (item) {
        const thumbnail = S.optionalText(item, "ThumbnailFilePath");
        if (thumbnail && !mediaPaths[thumbnail]) {
          throw engineError("validation", "Miniatura non collegata: " + thumbnail);
        }
      });
    } finally {
      database.close();
    }
  }

  function DatabaseMerger(leftDb, rightDb, leftManifest, rightManifest, resolutions, highlightMode) {
    this.data = { left: {}, right: {} };
    this.maps = { left: {}, right: {} };
    this.pathMaps = { left: {}, right: {} };
    this.blockRangesByMark = { left: {}, right: {} };
    this.merged = {};
    this.winnerByMark = {};
    this.resolutions = resolutions || {};
    this.highlightMode = highlightMode || "both";
    this.conflicts = [];
    const sources = ["left", "right"];
    const self = this;
    sources.forEach(function (source) {
      const database = source === "left" ? leftDb : rightDb;
      const sourceRows = {};
      TABLES.forEach(function (table) {
        sourceRows[table] = database.allRows(table);
      });
      self.data[source] = sourceRows;
      const grouped = {};
      (sourceRows.BlockRange || []).forEach(function (row) {
        const markID = S.optionalInt(row, "UserMarkId");
        if (markID !== null) {
          grouped[markID] = grouped[markID] || [];
          grouped[markID].push(row);
        }
      });
      self.blockRangesByMark[source] = grouped;
    });
    const leftDate = manifestDate(leftManifest);
    const rightDate = manifestDate(rightManifest);
    this.preferred = leftDate >= rightDate ? "left" : "right";
    TABLES.forEach(function (table) { self.merged[table] = []; });
  }

  function manifestDate(manifest) {
    const userData = manifest && manifest.userDataBackup;
    return A.parseDate(userData && userData.lastModifiedDate);
  }

  DatabaseMerger.prototype.rows = function (source, table) {
    return (this.data[source] && this.data[source][table]) || [];
  };

  DatabaseMerger.prototype.map = function (source, table, oldID) {
    const value = this.maps[source] && this.maps[source][table] && this.maps[source][table][oldID];
    if (value == null) throw engineError("missingMapping", source + " " + table + " ID " + oldID);
    return value;
  };

  DatabaseMerger.prototype.setMap = function (source, table, oldID, newID) {
    this.maps[source][table] = this.maps[source][table] || {};
    this.maps[source][table][oldID] = newID;
  };

  DatabaseMerger.prototype.nullableMap = function (source, table, value) {
    if (value === null || value === undefined) return S.nullValue();
    return S.integer(this.map(source, table, value));
  };

  DatabaseMerger.prototype.append = function (row, table) {
    this.merged[table].push(row);
  };

  DatabaseMerger.prototype.chosenSource = function (conflict) {
    const resolution = this.resolutions[conflict.id];
    if (resolution === "left" || resolution === "right") return resolution;
    return conflict.recommended;
  };

  DatabaseMerger.prototype.locationDescription = function (source, id) {
    if (id === null || id === undefined) return "Posizione non specificata";
    const location = this.rows(source, "Location").find(function (row) {
      return S.optionalInt(row, "LocationId") === id;
    });
    if (!location) return "Posizione non specificata";
    const components = [];
    const title = S.optionalText(location, "Title");
    if (title) components.push(title);
    const key = S.optionalText(location, "KeySymbol");
    if (key) components.push(key);
    const book = S.optionalInt(location, "BookNumber");
    if (book !== null) {
      const chapter = S.optionalInt(location, "ChapterNumber");
      components.push(chapter !== null ? "Libro " + book + ", capitolo " + chapter : "Libro " + book);
    }
    const document = S.optionalInt(location, "DocumentId");
    if (document !== null) components.push("Documento " + document);
    const track = S.optionalInt(location, "Track");
    if (track !== null) components.push("Traccia " + track);
    return components.length ? components.join(" · ") : "Posizione ID " + id;
  };

  function valueText(value) {
    if (!value || value.k === "n") return "—";
    if (value.k === "t") return value.v;
    if (value.k === "i" || value.k === "r") return String(value.v);
    if (value.k === "b") return value.v.length + " byte";
    return "—";
  }

  DatabaseMerger.prototype.blockRangeDescriptions = function (source, markID) {
    const ranges = (this.blockRangesByMark[source][markID] || []).slice().sort(function (a, b) {
      return (S.optionalInt(a, "BlockRangeId") || 0) - (S.optionalInt(b, "BlockRangeId") || 0);
    });
    return ranges.map(function (row) {
      const type = S.optionalInt(row, "BlockType") || 0;
      const identifier = S.optionalInt(row, "Identifier") || 0;
      return "Blocco " + type + ", ID " + identifier + ", token " + valueText(row.StartToken) + "–" + valueText(row.EndToken);
    });
  };

  DatabaseMerger.prototype.markSignature = function (source, row) {
    const mappedLocation = this.map(source, "Location", S.requireInt(row, "LocationId"));
    const ranges = this.blockRangeDescriptions(source, S.requireInt(row, "UserMarkId")).slice().sort();
    return [
      String(mappedLocation),
      valueText(row.ColorIndex),
      valueText(row.StyleIndex),
      valueText(row.Version),
      ranges.join("|")
    ].join("#");
  };

  function locationKeys(row) {
    function key(prefix, fields, requireAll) {
      const values = fields.map(function (field) { return row[field] || S.nullValue(); });
      if (requireAll && values.some(function (value) { return !value || value.k === "n"; })) return null;
      return prefix + "|" + values.map(S.stable).join("|");
    }
    const book = key("book", ["BookNumber", "ChapterNumber", "KeySymbol", "MepsLanguage", "Type"], true);
    let mediaFields = ["KeySymbol", "IssueTagNumber", "MepsLanguage", "DocumentId", "Track", "Type"]
      .map(function (field) { return row[field] || S.nullValue(); });
    if (!mediaFields.some(function (value) { return !value || value.k === "n"; })) {
      mediaFields = mediaFields.concat([row.Specialty || S.text(""), row.Edition || S.text("")]);
    }
    const media = mediaFields.slice(0, 6).some(function (value) { return !value || value.k === "n"; })
      ? null
      : "media|" + mediaFields.map(S.stable).join("|");
    const full = key("full", ["BookNumber", "ChapterNumber", "DocumentId", "Track", "IssueTagNumber", "KeySymbol", "MepsLanguage", "Type", "Specialty", "Edition"], false);
    return [book, media, full].filter(Boolean);
  }

  DatabaseMerger.prototype.mergeLocations = function () {
    const indexes = {};
    const rowIndexByID = {};
    let nextID = 1;
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "Location").forEach(function (original) {
        const keys = locationKeys(original);
        let existing = null;
        keys.forEach(function (item) {
          if (existing == null && indexes[item] != null) existing = indexes[item];
        });
        if (existing != null) {
          self.setMap(source, "Location", S.requireInt(original, "LocationId"), existing);
          const index = rowIndexByID[existing];
          if (index != null && !S.optionalText(self.merged.Location[index], "Title")) {
            const title = S.optionalText(original, "Title");
            if (title) self.merged.Location[index].Title = S.text(title);
          }
          return;
        }
        const record = S.cloneRow(original);
        record.LocationId = S.integer(nextID);
        rowIndexByID[nextID] = self.merged.Location.length;
        self.append(record, "Location");
        self.setMap(source, "Location", S.requireInt(original, "LocationId"), nextID);
        keys.forEach(function (item) { indexes[item] = nextID; });
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeUserMarks = function () {
    const byGuid = {};
    let nextID = 1;
    const self = this;
    (HIGHLIGHT_SOURCES[this.highlightMode] || HIGHLIGHT_SOURCES.both).forEach(function (source) {
      self.rows(source, "UserMark").forEach(function (original) {
        const guid = S.requireText(original, "UserMarkGuid");
        if (source === "right" && byGuid[guid]) {
          const match = byGuid[guid];
          self.setMap(source, "UserMark", S.requireInt(original, "UserMarkId"), match.id);
          if (self.markSignature("left", match.original) === self.markSignature("right", original)) return;
          const leftVersion = S.optionalInt(match.original, "Version") || 0;
          const rightVersion = S.optionalInt(original, "Version") || 0;
          const recommended = rightVersion > leftVersion ? "right" : (leftVersion > rightVersion ? "left" : self.preferred);
          const conflict = {
            id: "marking:" + guid,
            kind: "marking",
            context: self.locationDescription("left", S.optionalInt(match.original, "LocationId")),
            left: {
              title: "Colore " + (S.optionalInt(match.original, "ColorIndex") || 0),
              preview: self.blockRangeDescriptions("left", S.requireInt(match.original, "UserMarkId")).join("\n"),
              details: ["Versione: " + leftVersion, "Stile: " + (S.optionalInt(match.original, "StyleIndex") || 0)]
            },
            right: {
              title: "Colore " + (S.optionalInt(original, "ColorIndex") || 0),
              preview: self.blockRangeDescriptions("right", S.requireInt(original, "UserMarkId")).join("\n"),
              details: ["Versione: " + rightVersion, "Stile: " + (S.optionalInt(original, "StyleIndex") || 0)]
            },
            recommended: recommended
          };
          self.conflicts.push(conflict);
          const choice = self.chosenSource(conflict);
          self.winnerByMark[match.id] = choice;
          if (choice === "right") {
            const replacement = S.cloneRow(original);
            replacement.UserMarkId = S.integer(match.id);
            replacement.LocationId = S.integer(self.map(source, "Location", S.requireInt(original, "LocationId")));
            self.merged.UserMark[match.index] = replacement;
          }
          return;
        }
        const record = S.cloneRow(original);
        record.UserMarkId = S.integer(nextID);
        record.LocationId = S.integer(self.map(source, "Location", S.requireInt(original, "LocationId")));
        const index = self.merged.UserMark.length;
        self.append(record, "UserMark");
        self.setMap(source, "UserMark", S.requireInt(original, "UserMarkId"), nextID);
        self.winnerByMark[nextID] = source;
        byGuid[guid] = { id: nextID, index: index, original: original };
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.remapNote = function (source, original, id) {
    const record = S.cloneRow(original);
    record.NoteId = S.integer(id);
    record.LocationId = this.nullableMap(source, "Location", S.optionalInt(original, "LocationId"));
    const oldMarkID = S.optionalInt(original, "UserMarkId");
    const newMarkID = oldMarkID !== null && this.maps[source].UserMark ? this.maps[source].UserMark[oldMarkID] : null;
    record.UserMarkId = newMarkID == null ? S.nullValue() : S.integer(newMarkID);
    return record;
  };

  function earlierDateString(a, b) {
    const values = [a, b].filter(Boolean);
    if (!values.length) return null;
    return values.slice().sort(function (left, right) { return A.parseDate(left) - A.parseDate(right); })[0];
  }

  function laterDateString(a, b) {
    const values = [a, b].filter(Boolean);
    if (!values.length) return null;
    return values.slice().sort(function (left, right) { return A.parseDate(left) - A.parseDate(right); }).pop();
  }

  DatabaseMerger.prototype.mergeNotes = function () {
    const byGuid = {};
    let nextID = 1;
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "Note").forEach(function (original) {
        const guid = S.requireText(original, "Guid");
        if (source === "right" && byGuid[guid]) {
          const match = byGuid[guid];
          self.setMap(source, "Note", S.requireInt(original, "NoteId"), match.id);
          const leftDate = A.parseDate(S.optionalText(match.original, "LastModified") || "");
          const rightDate = A.parseDate(S.optionalText(original, "LastModified") || "");
          const differs = !S.valuesEqual(match.original.Title, original.Title) || !S.valuesEqual(match.original.Content, original.Content);
          if (differs) {
            const conflict = {
              id: "note:" + guid,
              kind: "note",
              context: self.locationDescription("left", S.optionalInt(match.original, "LocationId")),
              left: {
                title: S.optionalText(match.original, "Title") || "Nota senza titolo",
                preview: S.optionalText(match.original, "Content") || "",
                details: ["Modificata: " + (S.optionalText(match.original, "LastModified") || "—")]
              },
              right: {
                title: S.optionalText(original, "Title") || "Nota senza titolo",
                preview: S.optionalText(original, "Content") || "",
                details: ["Modificata: " + (S.optionalText(original, "LastModified") || "—")]
              },
              recommended: rightDate > leftDate ? "right" : "left"
            };
            self.conflicts.push(conflict);
            const resolution = self.resolutions[conflict.id] || conflict.recommended;
            if (resolution === "right") {
              self.merged.Note[match.index] = self.remapNote(source, original, match.id);
            } else if (resolution === "both") {
              const duplicate = self.remapNote(source, original, nextID);
              duplicate.Guid = S.text(crypto.randomUUID().toLowerCase());
              self.append(duplicate, "Note");
              self.setMap(source, "Note", S.requireInt(original, "NoteId"), nextID);
              nextID += 1;
            }
            return;
          }
          const created = earlierDateString(S.optionalText(match.original, "Created"), S.optionalText(original, "Created"));
          const modified = laterDateString(S.optionalText(match.original, "LastModified"), S.optionalText(original, "LastModified"));
          if (created) self.merged.Note[match.index].Created = S.text(created);
          if (modified) self.merged.Note[match.index].LastModified = S.text(modified);
          return;
        }
        const record = self.remapNote(source, original, nextID);
        const index = self.merged.Note.length;
        self.append(record, "Note");
        self.setMap(source, "Note", S.requireInt(original, "NoteId"), nextID);
        byGuid[guid] = { id: nextID, index: index, original: original };
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeBlockRanges = function () {
    let nextID = 1;
    const self = this;
    (HIGHLIGHT_SOURCES[this.highlightMode] || HIGHLIGHT_SOURCES.both).forEach(function (source) {
      self.rows(source, "BlockRange").forEach(function (original) {
        const parent = self.map(source, "UserMark", S.requireInt(original, "UserMarkId"));
        if (self.winnerByMark[parent] !== source) return;
        const record = S.cloneRow(original);
        record.BlockRangeId = S.integer(nextID);
        record.UserMarkId = S.integer(parent);
        self.append(record, "BlockRange");
        self.setMap(source, "BlockRange", S.requireInt(original, "BlockRangeId"), nextID);
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeBookmarks = function () {
    const occupied = {};
    let nextID = 1;
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "Bookmark").forEach(function (original) {
        const location = self.map(source, "Location", S.requireInt(original, "LocationId"));
        const publication = self.map(source, "Location", S.requireInt(original, "PublicationLocationId"));
        const slot = S.requireInt(original, "Slot");
        const key = publication + "|" + slot;
        if (occupied[key]) {
          const existing = occupied[key];
          self.setMap(source, "Bookmark", S.requireInt(original, "BookmarkId"), existing.id);
          const current = self.merged.Bookmark[existing.index] || {};
          const identical = S.optionalInt(current, "LocationId") === location
            && S.valuesEqual(current.Title, original.Title)
            && S.valuesEqual(current.Snippet, original.Snippet)
            && S.valuesEqual(current.BlockType, original.BlockType)
            && S.valuesEqual(current.BlockIdentifier, original.BlockIdentifier);
          if (identical) return;
          const conflict = {
            id: "bookmark:" + publication + ":" + slot,
            kind: "bookmark",
            context: self.locationDescription(existing.source, S.optionalInt(existing.original, "PublicationLocationId")) + " · Slot " + slot,
            left: {
              title: S.optionalText(existing.original, "Title") || "Segnalibro senza titolo",
              preview: S.optionalText(existing.original, "Snippet") || "",
              details: [
                self.locationDescription(existing.source, S.optionalInt(existing.original, "LocationId")),
                "Blocco: " + valueText(existing.original.BlockIdentifier)
              ]
            },
            right: {
              title: S.optionalText(original, "Title") || "Segnalibro senza titolo",
              preview: S.optionalText(original, "Snippet") || "",
              details: [
                self.locationDescription(source, S.optionalInt(original, "LocationId")),
                "Blocco: " + valueText(original.BlockIdentifier)
              ]
            },
            recommended: self.preferred
          };
          self.conflicts.push(conflict);
          if (self.chosenSource(conflict) === source) {
            const replacement = S.cloneRow(original);
            replacement.BookmarkId = S.integer(existing.id);
            replacement.LocationId = S.integer(location);
            replacement.PublicationLocationId = S.integer(publication);
            self.merged.Bookmark[existing.index] = replacement;
          }
          return;
        }
        const record = S.cloneRow(original);
        record.BookmarkId = S.integer(nextID);
        record.LocationId = S.integer(location);
        record.PublicationLocationId = S.integer(publication);
        const index = self.merged.Bookmark.length;
        self.append(record, "Bookmark");
        self.setMap(source, "Bookmark", S.requireInt(original, "BookmarkId"), nextID);
        occupied[key] = { id: nextID, index: index, source: source, original: original };
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeAccuracy = function () {
    const descriptions = {};
    let nextID = 1;
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "PlaylistItemAccuracy").forEach(function (original) {
        const description = S.requireText(original, "Description");
        if (descriptions[description] != null) {
          self.setMap(source, "PlaylistItemAccuracy", S.requireInt(original, "PlaylistItemAccuracyId"), descriptions[description]);
          return;
        }
        const record = S.cloneRow(original);
        record.PlaylistItemAccuracyId = S.integer(nextID);
        self.append(record, "PlaylistItemAccuracy");
        self.setMap(source, "PlaylistItemAccuracy", S.requireInt(original, "PlaylistItemAccuracyId"), nextID);
        descriptions[description] = nextID;
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeMedia = function () {
    const byHash = {};
    const usedPaths = {};
    let nextID = 1;
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "IndependentMedia").forEach(function (original) {
        const hash = S.requireText(original, "Hash");
        const oldPath = S.requireText(original, "FilePath");
        if (source === "right" && byHash[hash]) {
          const existing = byHash[hash];
          self.setMap(source, "IndependentMedia", S.requireInt(original, "IndependentMediaId"), existing.id);
          self.pathMaps[source][oldPath] = existing.path;
          return;
        }
        let targetPath = oldPath;
        if (usedPaths[targetPath] && usedPaths[targetPath] !== hash) {
          const lastDot = oldPath.lastIndexOf(".");
          const slash = oldPath.lastIndexOf("/");
          const ext = lastDot > slash ? oldPath.slice(lastDot) : "";
          const stem = lastDot > slash ? oldPath.slice(0, lastDot) : oldPath;
          targetPath = stem + "-merged-" + source + "-" + S.requireInt(original, "IndependentMediaId") + ext;
          while (usedPaths[targetPath]) {
            targetPath = stem + "-merged-" + crypto.randomUUID().slice(0, 8) + ext;
          }
        }
        const record = S.cloneRow(original);
        record.IndependentMediaId = S.integer(nextID);
        record.FilePath = S.text(targetPath);
        self.append(record, "IndependentMedia");
        self.setMap(source, "IndependentMedia", S.requireInt(original, "IndependentMediaId"), nextID);
        self.pathMaps[source][oldPath] = targetPath;
        usedPaths[targetPath] = hash;
        if (!byHash[hash]) byHash[hash] = { id: nextID, path: targetPath };
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.playlistMemberships = function (source) {
    const tags = {};
    this.rows(source, "Tag").forEach(function (row) {
      const id = S.optionalInt(row, "TagId");
      if (id !== null) tags[id] = row;
    });
    const result = {};
    this.rows(source, "TagMap").forEach(function (mapping) {
      const item = S.optionalInt(mapping, "PlaylistItemId");
      const tagID = S.optionalInt(mapping, "TagId");
      if (item === null || tagID === null || !tags[tagID] || S.optionalInt(tags[tagID], "Type") !== 2) return;
      const name = S.optionalText(tags[tagID], "Name");
      if (!name) return;
      result[item] = result[item] || [];
      result[item].push(name);
    });
    return result;
  };

  DatabaseMerger.prototype.playlistFingerprint = function (source, item) {
    const itemID = S.requireInt(item, "PlaylistItemId");
    const memberships = (this.playlistMemberships(source)[itemID] || []).slice().sort();
    const mediaByID = {};
    const hashByPath = {};
    this.rows(source, "IndependentMedia").forEach(function (row) {
      const id = S.optionalInt(row, "IndependentMediaId");
      if (id !== null) mediaByID[id] = row;
      const path = S.optionalText(row, "FilePath");
      const hash = S.optionalText(row, "Hash");
      if (path && hash) hashByPath[path] = hash;
    });
    const self = this;
    const locations = [];
    this.rows(source, "PlaylistItemLocationMap").forEach(function (mapping) {
      if (S.optionalInt(mapping, "PlaylistItemId") !== itemID) return;
      const mappedLocation = self.map(source, "Location", S.requireInt(mapping, "LocationId"));
      locations.push(mappedLocation + "|" + S.stable(mapping.MajorMultimediaType || S.nullValue()) + "|" + S.stable(mapping.BaseDurationTicks || S.nullValue()));
    });
    const media = [];
    this.rows(source, "PlaylistItemIndependentMediaMap").forEach(function (mapping) {
      if (S.optionalInt(mapping, "PlaylistItemId") !== itemID) return;
      const oldMediaID = S.optionalInt(mapping, "IndependentMediaId");
      const medium = oldMediaID !== null ? mediaByID[oldMediaID] : null;
      if (!medium) return;
      media.push(S.stable(medium.Hash || S.nullValue()) + "|" + S.stable(mapping.DurationTicks || S.nullValue()));
    });
    const markerChildren = {};
    this.rows(source, "PlaylistItemMarkerBibleVerseMap").forEach(function (verse) {
      const marker = S.optionalInt(verse, "PlaylistItemMarkerId");
      if (marker === null) return;
      markerChildren[marker] = markerChildren[marker] || [];
      markerChildren[marker].push("v|" + S.stable(verse.VerseId || S.nullValue()));
    });
    this.rows(source, "PlaylistItemMarkerParagraphMap").forEach(function (paragraph) {
      const marker = S.optionalInt(paragraph, "PlaylistItemMarkerId");
      if (marker === null) return;
      markerChildren[marker] = markerChildren[marker] || [];
      markerChildren[marker].push("p|" + S.stable(paragraph.MepsDocumentId || S.nullValue()) + "|" + S.stable(paragraph.ParagraphIndex || S.nullValue()) + "|" + S.stable(paragraph.MarkerIndexWithinParagraph || S.nullValue()));
    });
    const markers = [];
    this.rows(source, "PlaylistItemMarker").forEach(function (marker) {
      if (S.optionalInt(marker, "PlaylistItemId") !== itemID) return;
      const markerID = S.requireInt(marker, "PlaylistItemMarkerId");
      const children = (markerChildren[markerID] || []).slice().sort().join(",");
      markers.push(["Label", "StartTimeTicks", "DurationTicks", "EndTransitionDurationTicks"].map(function (key) {
        return S.stable(marker[key] || S.nullValue());
      }).join("|") + "|" + children);
    });
    const thumbnailHash = hashByPath[S.optionalText(item, "ThumbnailFilePath") || ""] || "";
    const main = ["Label", "StartTrimOffsetTicks", "EndTrimOffsetTicks", "EndAction"].map(function (key) {
      return S.stable(item[key] || S.nullValue());
    }).join("|");
    const accuracy = this.map(source, "PlaylistItemAccuracy", S.requireInt(item, "Accuracy"));
    return [
      memberships.join(","), main, String(accuracy), thumbnailHash,
      locations.slice().sort().join(","), media.slice().sort().join(","),
      markers.slice().sort().join(",")
    ].join("#");
  };

  DatabaseMerger.prototype.mergePlaylistItems = function () {
    const seen = {};
    let nextID = 1;
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "PlaylistItem").forEach(function (original) {
        const fingerprint = self.playlistFingerprint(source, original);
        if (source === "right" && seen[fingerprint] != null) {
          self.setMap(source, "PlaylistItem", S.requireInt(original, "PlaylistItemId"), seen[fingerprint]);
          return;
        }
        const record = S.cloneRow(original);
        record.PlaylistItemId = S.integer(nextID);
        record.Accuracy = S.integer(self.map(source, "PlaylistItemAccuracy", S.requireInt(original, "Accuracy")));
        const thumbnail = S.optionalText(original, "ThumbnailFilePath");
        if (thumbnail) {
          const mappedPath = self.pathMaps[source][thumbnail];
          if (!mappedPath) throw engineError("missingMapping", "miniatura " + thumbnail);
          record.ThumbnailFilePath = S.text(mappedPath);
        }
        self.append(record, "PlaylistItem");
        self.setMap(source, "PlaylistItem", S.requireInt(original, "PlaylistItemId"), nextID);
        seen[fingerprint] = nextID;
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeMarkers = function () {
    const seen = {};
    let nextID = 1;
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "PlaylistItemMarker").forEach(function (original) {
        const parent = self.map(source, "PlaylistItem", S.requireInt(original, "PlaylistItemId"));
        const key = parent + "|" + S.requireInt(original, "StartTimeTicks");
        if (seen[key] != null) {
          self.setMap(source, "PlaylistItemMarker", S.requireInt(original, "PlaylistItemMarkerId"), seen[key]);
          return;
        }
        const record = S.cloneRow(original);
        record.PlaylistItemMarkerId = S.integer(nextID);
        record.PlaylistItemId = S.integer(parent);
        self.append(record, "PlaylistItemMarker");
        self.setMap(source, "PlaylistItemMarker", S.requireInt(original, "PlaylistItemMarkerId"), nextID);
        seen[key] = nextID;
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeSimpleMap = function (table, foreignKeys, keyColumns) {
    const seen = {};
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, table).forEach(function (original) {
        const record = S.cloneRow(original);
        Object.keys(foreignKeys).forEach(function (column) {
          record[column] = S.integer(self.map(source, foreignKeys[column], S.requireInt(original, column)));
        });
        const key = keyColumns.map(function (column) { return S.stable(record[column] || S.nullValue()); }).join("|");
        if (!seen[key]) {
          seen[key] = true;
          self.append(record, table);
        }
      });
    });
  };

  DatabaseMerger.prototype.mergeTags = function () {
    const seen = {};
    let nextID = 1;
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "Tag").forEach(function (original) {
        const key = S.requireInt(original, "Type") + "|" + S.requireText(original, "Name");
        if (seen[key] != null) {
          self.setMap(source, "Tag", S.requireInt(original, "TagId"), seen[key]);
          return;
        }
        const record = S.cloneRow(original);
        record.TagId = S.integer(nextID);
        self.append(record, "Tag");
        self.setMap(source, "Tag", S.requireInt(original, "TagId"), nextID);
        seen[key] = nextID;
        nextID += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeTagMaps = function () {
    const grouped = {};
    const self = this;
    ["left", "right"].forEach(function (source) {
      const sorted = self.rows(source, "TagMap").slice().sort(function (a, b) {
        const left = [S.optionalInt(a, "TagId") || 0, S.optionalInt(a, "Position") || 0, S.optionalInt(a, "TagMapId") || 0];
        const right = [S.optionalInt(b, "TagId") || 0, S.optionalInt(b, "Position") || 0, S.optionalInt(b, "TagMapId") || 0];
        if (left[0] !== right[0]) return left[0] - right[0];
        if (left[1] !== right[1]) return left[1] - right[1];
        return left[2] - right[2];
      });
      sorted.forEach(function (original) {
        const tag = self.map(source, "Tag", S.requireInt(original, "TagId"));
        let key;
        const note = S.optionalInt(original, "NoteId");
        const location = S.optionalInt(original, "LocationId");
        const playlist = S.optionalInt(original, "PlaylistItemId");
        if (note !== null) key = "note|" + self.map(source, "Note", note);
        else if (location !== null) key = "location|" + self.map(source, "Location", location);
        else if (playlist !== null) key = "playlist|" + self.map(source, "PlaylistItem", playlist);
        else throw new Error("Riga database non valida: TagMap senza destinazione");
        grouped[tag] = grouped[tag] || [];
        grouped[tag].push({ targetKey: key, source: source, original: original });
      });
    });
    let nextID = 1;
    Object.keys(grouped).map(Number).sort(function (a, b) { return a - b; }).forEach(function (tag) {
      const seen = {};
      let position = 0;
      grouped[tag].forEach(function (entry) {
        if (seen[entry.targetKey]) return;
        seen[entry.targetKey] = true;
        const components = entry.targetKey.split("|");
        const target = Number(components[1]);
        const record = {
          TagMapId: S.integer(nextID),
          PlaylistItemId: S.nullValue(),
          LocationId: S.nullValue(),
          NoteId: S.nullValue(),
          TagId: S.integer(tag),
          Position: S.integer(position)
        };
        if (components[0] === "note") record.NoteId = S.integer(target);
        if (components[0] === "location") record.LocationId = S.integer(target);
        if (components[0] === "playlist") record.PlaylistItemId = S.integer(target);
        self.append(record, "TagMap");
        self.setMap(entry.source, "TagMap", S.requireInt(entry.original, "TagMapId"), nextID);
        nextID += 1;
        position += 1;
      });
    });
  };

  DatabaseMerger.prototype.mergeInputFields = function () {
    const indexes = {};
    const self = this;
    ["left", "right"].forEach(function (source) {
      self.rows(source, "InputField").forEach(function (original) {
        const record = S.cloneRow(original);
        const location = self.map(source, "Location", S.requireInt(original, "LocationId"));
        record.LocationId = S.integer(location);
        const textTag = S.requireText(original, "TextTag");
        const key = location + "|" + textTag;
        if (indexes[key]) {
          const existing = indexes[key];
          if (S.valuesEqual(self.merged.InputField[existing.index].Value, record.Value)) return;
          const conflict = {
            id: "inputField:" + location + ":" + textTag,
            kind: "inputField",
            context: self.locationDescription(existing.source, S.optionalInt(existing.original, "LocationId")),
            left: {
              title: valueText(existing.original.Value),
              preview: textTag,
              details: ["Valore salvato nel primo backup"]
            },
            right: {
              title: valueText(original.Value),
              preview: textTag,
              details: ["Valore salvato nel secondo backup"]
            },
            recommended: self.preferred
          };
          self.conflicts.push(conflict);
          if (self.chosenSource(conflict) === source) {
            self.merged.InputField[existing.index].Value = record.Value;
          }
        } else {
          indexes[key] = { index: self.merged.InputField.length, source: source, original: original };
          self.append(record, "InputField");
        }
      });
    });
  };

  DatabaseMerger.prototype.run = function () {
    this.mergeLocations();
    this.mergeUserMarks();
    this.mergeNotes();
    this.mergeBlockRanges();
    this.mergeBookmarks();
    this.mergeAccuracy();
    this.mergeMedia();
    this.mergePlaylistItems();
    this.mergeMarkers();
    this.mergeSimpleMap("PlaylistItemIndependentMediaMap", { PlaylistItemId: "PlaylistItem", IndependentMediaId: "IndependentMedia" }, ["PlaylistItemId", "IndependentMediaId"]);
    this.mergeSimpleMap("PlaylistItemLocationMap", { PlaylistItemId: "PlaylistItem", LocationId: "Location" }, ["PlaylistItemId", "LocationId"]);
    this.mergeSimpleMap("PlaylistItemMarkerBibleVerseMap", { PlaylistItemMarkerId: "PlaylistItemMarker" }, ["PlaylistItemMarkerId", "VerseId"]);
    this.mergeSimpleMap("PlaylistItemMarkerParagraphMap", { PlaylistItemMarkerId: "PlaylistItemMarker" }, ["PlaylistItemMarkerId", "MepsDocumentId", "ParagraphIndex", "MarkerIndexWithinParagraph"]);
    this.mergeTags();
    this.mergeTagMaps();
    this.mergeInputFields();
    return { rows: this.merged, pathMaps: this.pathMaps, conflicts: this.conflicts };
  };

  function openDatabases(left, right) {
    const leftDb = new S.SQLiteDatabase(left.database, true);
    const rightDb = new S.SQLiteDatabase(right.database, true);
    inspect(leftDb, left.name);
    inspect(rightDb, right.name);
    return { leftDb: leftDb, rightDb: rightDb };
  }

  async function analyze(leftFile, rightFile, highlightMode) {
    const left = await A.extract(leftFile.buffer);
    left.name = leftFile.name;
    const right = await A.extract(rightFile.buffer);
    right.name = rightFile.name;
    const opened = openDatabases(left, right);
    try {
      const merger = new DatabaseMerger(opened.leftDb, opened.rightDb, left.manifest, right.manifest, {}, highlightMode);
      const result = merger.run();
      return { leftName: leftFile.name, rightName: rightFile.name, conflicts: result.conflicts };
    } finally {
      opened.leftDb.close();
      opened.rightDb.close();
    }
  }

  async function merge(leftFile, rightFile, resolutions, highlightMode) {
    const left = await A.extract(leftFile.buffer);
    left.name = leftFile.name;
    const right = await A.extract(rightFile.buffer);
    right.name = rightFile.name;
    const opened = openDatabases(left, right);
    let result;
    try {
      const merger = new DatabaseMerger(opened.leftDb, opened.rightDb, left.manifest, right.manifest, resolutions || {}, highlightMode);
      result = merger.run();
    } finally {
      opened.leftDb.close();
      opened.rightDb.close();
    }
    const mergedDatabase = rebuildDatabase(left.database, result.rows);
    const assets = copyAssets(left, right, result.pathMaps);
    const outputName = "UserdataBackup_" + A.outputStamp(new Date()) + "_Merged.jwlibrary";
    const manifest = await A.writeManifest(left.manifest, outputName, mergedDatabase);
    const files = Object.assign({}, assets);
    files[A.DATABASE_NAME] = mergedDatabase;
    files[A.MANIFEST_NAME] = manifest;
    const archive = await A.createArchive(files);
    await validateArchive(archive);

    const counts = {};
    Object.keys(result.rows).forEach(function (table) { counts[table] = result.rows[table].length; });
    const playlistTagIds = {};
    (result.rows.Tag || []).forEach(function (row) {
      if (S.optionalInt(row, "Type") === 2) {
        const id = S.optionalInt(row, "TagId");
        if (id !== null) playlistTagIds[id] = true;
      }
    });
    const playlistSet = {};
    (result.rows.TagMap || []).forEach(function (row) {
      const tag = S.optionalInt(row, "TagId");
      if (tag !== null && playlistTagIds[tag]) playlistSet[tag] = true;
    });
    const conflictCounts = { bookmark: 0, marking: 0, note: 0, inputField: 0 };
    result.conflicts.forEach(function (item) { conflictCounts[item.kind] = (conflictCounts[item.kind] || 0) + 1; });
    return {
      filename: outputName,
      bytes: archive,
      notes: counts.Note || 0,
      highlights: counts.UserMark || 0,
      bookmarks: counts.Bookmark || 0,
      tags: counts.Tag || 0,
      inputFields: counts.InputField || 0,
      playlists: Object.keys(playlistSet).length,
      playlistItems: counts.PlaylistItem || 0,
      media: counts.IndependentMedia || 0,
      bookmarkConflicts: conflictCounts.bookmark,
      markingConflicts: conflictCounts.marking,
      noteConflicts: conflictCounts.note,
      inputFieldConflicts: conflictCounts.inputField
    };
  }

  root.BackupUniteEngine = { analyze: analyze, merge: merge };
})(typeof self !== "undefined" ? self : window);
