/*
 * MusicFree plugin compatibility preload for iMusic.
 *
 * IMPORTANT: this file is intentionally separate from LXUserAPIPreload.js.
 * The LX preload freezes globalThis and disables eval/Function; MusicFree
 * plugins are CommonJS modules and must run in their own JavaScriptCore
 * context. The native host functions installed before this script runs are
 * shared with the LX bridge, so networking / crypto / timers are reused.
 *
 * The plugin's methods are translated into the existing LX wire protocol:
 *   getMediaSource -> request(action:"musicUrl") -> {data:{url:...}}
 *   getLyric       -> request(action:"lyric")    -> {data:{lyric:...}}
 * Everything downstream (fallback playback, lock-screen lyrics, CarPlay)
 * therefore keeps using the untouched original code path.
 */
(function () {
  "use strict";

  var hostKey = "";
  var plugin = null;
  var pluginID = "";
  var pluginPlatform = "musicfree";
  var pendingHTTP = {};
  var pendingTimers = {};
  var timerSeq = 0;
  var userVariables = null;
  var diagnosticCount = 0;

  // JavaScriptCore has no atob/btoa. Provide them from the native bridge.
  if (typeof globalThis.btoa !== "function") {
    globalThis.btoa = function (value) {
      return typeof __lx_native_call__utils_str2b64 === "function"
        ? __lx_native_call__utils_str2b64(String(value)) : "";
    };
  }
  if (typeof globalThis.atob !== "function") {
    globalThis.atob = function (value) {
      return typeof __mf_b642str__ === "function" ? __mf_b642str__(String(value)) : "";
    };
  }

  function diag(message) {
    if (diagnosticCount < 40) {
      diagnosticCount += 1;
      if (typeof console !== "undefined" && console.log) {
        console.log("[MusicFree] " + message);
      }
    }
  }

  function native(action, payload) {
    if (typeof __lx_native_call__ !== "function") { return; }
    try {
      __lx_native_call__(hostKey, action, JSON.stringify(payload || {}));
    } catch (error) {
      diag("native call failed: " + error);
    }
  }

  function respond(requestKey, result, errorMessage) {
    if (!requestKey) { return; }
    native("response", {
      requestKey: requestKey,
      status: errorMessage ? false : true,
      result: result || {},
      errorMessage: errorMessage || ""
    });
  }

  // ------------------------------------------------------------------
  // Small JSON / string helpers (JSC has no Node globals)
  // ------------------------------------------------------------------
  function parseJSON(text, fallback) {
    if (text == null) { return fallback; }
    if (typeof text === "object") { return text; }
    try { return JSON.parse(text); } catch (error) { return fallback; }
  }

  function utf8Bytes(text) {
    var s = String(text == null ? "" : text);
    var out = [];
    for (var i = 0; i < s.length; i += 1) {
      var c = s.charCodeAt(i);
      if (c < 0x80) { out.push(c); }
      else if (c < 0x800) {
        out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
        var low = s.charCodeAt(i + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          var cp = 0x10000 + ((c - 0xd800) << 10) + (low - 0xdc00);
          out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
                   0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
          i += 1;
        } else { out.push(0xef, 0xbf, 0xbd); }
      } else if (c >= 0xd800 && c <= 0xdfff) { out.push(0xef, 0xbf, 0xbd); }
      else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
    }
    return out;
  }

  function bytesToString(bytes) {
    var out = "", chunk = [];
    for (var i = 0; i < bytes.length; i += 1) {
      chunk.push(bytes[i] & 0xff);
      if (chunk.length >= 8192) { out += decodeUTF8(chunk); chunk = []; }
    }
    return out + decodeUTF8(chunk);
  }

  function decodeUTF8(bytes) {
    var out = "";
    for (var i = 0; i < bytes.length; i += 1) {
      var b = bytes[i];
      if (b < 0x80) { out += String.fromCharCode(b); }
      else if (b < 0xe0 && i + 1 < bytes.length) {
        out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f)); i += 1;
      } else if (b < 0xf0 && i + 2 < bytes.length) {
        out += String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f)); i += 2;
      } else if (i + 3 < bytes.length) {
        var cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) |
                 ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff)); i += 3;
      }
    }
    return out;
  }

  function hexOf(text) {
    var bytes = utf8Bytes(text), out = "";
    for (var i = 0; i < bytes.length; i += 1) {
      out += (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16);
    }
    return out;
  }

  function stringsToArgs(values) {
    var args = [], i;
    for (i = 0; i < values.length; i += 1) {
      var v = values[i];
      if (v && typeof v === "object" && typeof v.toString === "function" && v.words !== undefined) {
        args.push(v.toString(CryptoJS.enc.Utf8));
      } else { args.push(String(v == null ? "" : v)); }
    }
    return args;
  }

  // ------------------------------------------------------------------
  // URL / URLSearchParams polyfills (JavaScriptCore has neither)
  // ------------------------------------------------------------------
  function URLSearchParamsPolyfill(init) {
    var pairs = [];
    var self = this;
    function appendFrom(text) {
      String(text == null ? "" : text).replace(/^\?/, "").split("&").forEach(function (part) {
        if (!part) { return; }
        var at = part.indexOf("=");
        var k = at < 0 ? part : part.slice(0, at);
        var v = at < 0 ? "" : part.slice(at + 1);
        pairs.push([decodeURIComponentSafe(k), decodeURIComponentSafe(v)]);
      });
    }
    if (typeof init === "string") { appendFrom(init); }
    else if (init instanceof URLSearchParamsPolyfill) { pairs = init._pairs.slice(); }
    else if (init && typeof init === "object") {
      Object.keys(init).forEach(function (k) {
        var value = init[k];
        if (Array.isArray(value)) { value.forEach(function (v) { pairs.push([k, String(v)]); }); }
        else { pairs.push([k, String(value == null ? "" : value)]); }
      });
    }
    this._pairs = pairs;
    this.append = function (k, v) { pairs.push([String(k), String(v == null ? "" : v)]); };
    this.set = function (k, v) {
      var done = false;
      pairs.forEach(function (pair, index) {
        if (pair[0] === String(k)) {
          if (!done) { pairs[index] = [String(k), String(v == null ? "" : v)]; done = true; }
          else { pairs[index] = [null, null]; }
        }
      });
      pairs = pairs.filter(function (pair) { return pair[0] !== null; });
      self._pairs = pairs;
    };
    this.get = function (k) {
      for (var i = 0; i < pairs.length; i += 1) { if (pairs[i][0] === String(k)) { return pairs[i][1]; } }
      return null;
    };
    this.getAll = function (k) { return pairs.filter(function (p) { return p[0] === String(k); }).map(function (p) { return p[1]; }); };
    this.has = function (k) { return this.get(k) !== null; };
    this.delete = function (k) { pairs = pairs.filter(function (p) { return p[0] !== String(k); }); self._pairs = pairs; };
    this.sort = function () { pairs.sort(function (a, b) { return String(a[0]).localeCompare(String(b[0])); }); };
    this.forEach = function (fn) { pairs.forEach(function (p) { fn(p[1], p[0], self); }); };
    this.keys = function () { return pairs.map(function (p) { return p[0]; }); };
    this.values = function () { return pairs.map(function (p) { return p[1]; }); };
    this.entries = function () { return pairs.slice(); };
    this.toString = function () {
      return pairs.map(function (p) {
        return encodeURIComponentSafe(p[0]) + "=" + encodeURIComponentSafe(p[1]);
      }).join("&");
    };
  }
  function encodeURIComponentSafe(value) {
    return encodeURIComponent(String(value)).replace(/[!'()*]/g, function (c) {
      return "%" + c.charCodeAt(0).toString(16).toUpperCase();
    });
  }
  function decodeURIComponentSafe(value) {
    try { return decodeURIComponent(String(value).replace(/\+/g, " ")); }
    catch (error) { return String(value); }
  }

  function URLPolyfill(input, base) {
    var text = String(input == null ? "" : input);
    if (base && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(text)) {
      var b = String(base);
      var cut = b.indexOf("//");
      if (text.indexOf("/") === 0 && cut >= 0) { text = b.slice(0, b.indexOf("/", cut + 2) < 0 ? b.length : b.indexOf("/", cut + 2)) + text; }
      else if (cut >= 0) { text = b.slice(0, b.lastIndexOf("/") + 1) + text; }
    }
    var match = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(text);
    if (!match) {
      match = /^([a-zA-Z][a-zA-Z0-9+.-]*):([^?#]*)(\?[^#]*)?(#.*)?$/.exec(text);
    }
    this.href = text;
    this.protocol = match && match[1] ? match[1].toLowerCase() + ":" : "";
    this.host = match && match[2] ? match[2] : "";
    this.hostname = this.host.replace(/:[0-9]+$/, "");
    this.pathname = match && match[3] ? match[3] : "";
    if (this.pathname && this.pathname[0] !== "/" && this.host) { this.pathname = "/" + this.pathname; }
    var query = match && (match[4] || match[3] && text.indexOf("?") >= 0 ? (match[4] || "") : "");
    if (!query) { var q = text.indexOf("?"); if (q >= 0) { query = text.slice(q, text.indexOf("#") < 0 ? text.length : text.indexOf("#")); } }
    this.search = query || "";
    this.hash = (match && match[5]) || (text.indexOf("#") >= 0 ? text.slice(text.indexOf("#")) : "");
    this.searchParams = new URLSearchParamsPolyfill(this.search);
    this.username = "";
    this.password = "";
    this.port = /:([0-9]+)$/.exec(this.host) ? /:([0-9]+)$/.exec(this.host)[1] : "";
    this.origin = this.host ? this.protocol + "//" + this.host : "";
    var self = this;
    this.toString = function () { return self.href; };
  }

  // ------------------------------------------------------------------
  // Buffer / TextEncoder / base64
  // ------------------------------------------------------------------
  function BufferPolyfill(value, encoding) {
    var bytes = [];
    if (typeof value === "string") {
      var enc = (encoding || "utf8").toLowerCase();
      if (enc === "base64") {
        var text = typeof atob === "function" ? atob(value) : "";
        for (var i = 0; i < text.length; i += 1) { bytes.push(text.charCodeAt(i) & 0xff); }
      } else if (enc === "hex") {
        for (var h = 0; h + 1 < value.length; h += 2) { bytes.push(parseInt(value.slice(h, h + 2), 16)); }
      } else { bytes = utf8Bytes(value); }
    } else if (value instanceof ArrayBuffer) {
      bytes = Array.prototype.slice.call(new Uint8Array(value));
    } else if (Array.isArray(value)) { bytes = value.slice(); }
    this._bytes = bytes;
    this.length = bytes.length;
    var self = this;
    this.toString = function (encodingName) {
      var enc = (encodingName || "utf8").toLowerCase();
      if (enc === "hex") {
        return bytes.map(function (b) { return (b < 16 ? "0" : "") + (b & 0xff).toString(16); }).join("");
      }
      if (enc === "base64") { return typeof btoa === "function" ? btoa(bytesToString(bytes)) : ""; }
      return bytesToString(bytes);
    };
    this.toJSON = function () { return { type: "Buffer", data: bytes }; };
    this.slice = function (start, end) { return new BufferPolyfill(bytes.slice(start, end)); };
    this.equals = function (other) {
      var b = other && other._bytes ? other._bytes : [];
      return b.length === bytes.length && bytes.every(function (v, i) { return v === b[i]; });
    };
    this.readUInt8 = function (i) { return bytes[i]; };
    this.writeUInt8 = function (v, i) { bytes[i] = v & 0xff; self.length = bytes.length; return i + 1; };
  }
  BufferPolyfill.from = function (value, encoding) { return new BufferPolyfill(value, encoding); };
  BufferPolyfill.alloc = function (size) { return new BufferPolyfill(new Array(size).fill(0)); };
  BufferPolyfill.isBuffer = function (value) { return value instanceof BufferPolyfill; };

  // ------------------------------------------------------------------
  // HTML entities (he)
  // ------------------------------------------------------------------
  var namedEntities = {
    amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0",
    copy: "\u00a9", reg: "\u00ae", hellip: "\u2026", mdash: "\u2014",
    ndash: "\u2013", laquo: "\u00ab", raquo: "\u00bb", middot: "\u00b7",
    bull: "\u2022", times: "\u00d7", divide: "\u00f7", trade: "\u2122",
    eacute: "\u00e9", aacute: "\u00e1", oacute: "\u00f3", uacute: "\u00fa",
    iacute: "\u00ed", ntilde: "\u00f1", ccedil: "\u00e7",agrave:"\u00e0",
    egrave:"\u00e8",ograve:"\u00f2",ugrave:"\u00f9",iuml:"\u00ef",euml:"\u00eb"
  };
  function decodeEntities(text) {
    return String(text == null ? "" : text).replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]+);?/g, function (m, code) {
      if (code[0] === "#") {
        var value = code[1] === "x" || code[1] === "X"
          ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
        if (isNaN(value)) { return m; }
        try { return String.fromCodePoint ? String.fromCodePoint(value) : String.fromCharCode(value); }
        catch (error) { return ""; }
      }
      return namedEntities[code.toLowerCase()] !== undefined ? namedEntities[code.toLowerCase()] : m;
    });
  }
  function encodeEntities(text, quote) {
    var out = String(text == null ? "" : text);
    out = out.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    if (quote) { out = out.replace(/"/g, "&quot;").replace(/'/g, "&#39;"); }
    return out;
  }
  var heModule = {
    decode: decodeEntities,
    encode: function (text) { return encodeEntities(text, false); },
    escape: function (text) { return encodeEntities(text, false); },
    unescape: decodeEntities
  };

  // ------------------------------------------------------------------
  // qs
  // ------------------------------------------------------------------
  function qsStringify(value, prefix) {
    if (value == null) { return ""; }
    if (Array.isArray(value)) {
      return value.map(function (item) {
        return qsStringify(item, prefix ? prefix + "[]" : "[]");
      }).filter(Boolean).join("&");
    }
    if (typeof value === "object") {
      return Object.keys(value).map(function (key) {
        return qsStringify(value[key], prefix ? prefix + "[" + key + "]" : key);
      }).filter(Boolean).join("&");
    }
    return encodeURIComponentSafe(prefix || "") + "=" + encodeURIComponentSafe(value);
  }
  var qsModule = {
    stringify: function (value) { return qsStringify(value, ""); },
    parse: function (text) {
      var result = {};
      String(text || "").replace(/^\?/, "").split("&").forEach(function (part) {
        if (!part) { return; }
        var at = part.indexOf("=");
        var key = decodeURIComponentSafe(at < 0 ? part : part.slice(0, at));
        var value = decodeURIComponentSafe(at < 0 ? "" : part.slice(at + 1));
        result[key] = value;
      });
      return result;
    }
  };

  // ------------------------------------------------------------------
  // dayjs (formatting subset used by plugins)
  // ------------------------------------------------------------------
  function pad(n, width) { var s = String(n); while (s.length < (width || 2)) { s = "0" + s; } return s; }
  function dayjs(input) {
    var date;
    if (input === undefined || input === null) { date = new Date(); }
    else if (input instanceof Date) { date = new Date(input.getTime()); }
    else if (typeof input === "number") { date = new Date(input < 1e12 ? input * 1000 : input); }
    else { date = new Date(String(input).replace(/-/g, "/")); }
    if (isNaN(date.getTime())) { date = new Date(); }
    var value = {
      $d: date,
      valueOf: function () { return date.getTime(); },
      unix: function () { return Math.floor(date.getTime() / 1000); },
      toISOString: function () { return date.toISOString(); },
      toDate: function () { return new Date(date.getTime()); },
      isValid: function () { return !isNaN(date.getTime()); },
      format: function (pattern) {
        var map = {
          YYYY: date.getFullYear(), YY: pad(date.getFullYear() % 100),
          MM: pad(date.getMonth() + 1), M: date.getMonth() + 1,
          DD: pad(date.getDate()), D: date.getDate(),
          HH: pad(date.getHours()), H: date.getHours(),
          mm: pad(date.getMinutes()), m: date.getMinutes(),
          ss: pad(date.getSeconds()), s: date.getSeconds(),
          SSS: pad(date.getMilliseconds(), 3)
        };
        return String(pattern || "YYYY-MM-DD HH:mm:ss").replace(/YYYY|YY|MM|DD|HH|mm|ss|SSS|M|D|H|m|s/g, function (key) {
          return map[key] !== undefined ? String(map[key]) : key;
        });
      },
      add: function (n, unit) { var d = new Date(date.getTime()); return dayjs(shift(d, n, unit)); },
      subtract: function (n, unit) { return dayjs(shift(new Date(date.getTime()), -n, unit)); },
      isBefore: function (other) { return date.getTime() < dayjs(other).valueOf(); },
      isAfter: function (other) { return date.getTime() > dayjs(other).valueOf(); },
      diff: function (other, unit) {
        var delta = date.getTime() - dayjs(other).valueOf();
        if (unit === "second") { return Math.floor(delta / 1000); }
        if (unit === "minute") { return Math.floor(delta / 60000); }
        if (unit === "hour") { return Math.floor(delta / 3600000); }
        if (unit === "day") { return Math.floor(delta / 86400000); }
        return delta;
      }
    };
    return value;
  }
  function shift(date, n, unit) {
    n = Number(n) || 0;
    if (unit === "year") { date.setFullYear(date.getFullYear() + n); }
    else if (unit === "month") { date.setMonth(date.getMonth() + n); }
    else if (unit === "day" || unit === "date") { date.setDate(date.getDate() + n); }
    else if (unit === "hour") { date.setHours(date.getHours() + n); }
    else if (unit === "minute") { date.setMinutes(date.getMinutes() + n); }
    else if (unit === "second") { date.setSeconds(date.getSeconds() + n); }
    else { date.setMilliseconds(date.getMilliseconds() + n); }
    return date;
  }
  dayjs.unix = function (seconds) { return dayjs(Number(seconds) * 1000); };
  dayjs.extend = function () {};

  // ------------------------------------------------------------------
  // big-integer (thin BigInt wrapper)
  // ------------------------------------------------------------------
  function bigInteger(value) {
    var v = (value && value._big) !== undefined ? value._big : BigInt(String(value == null ? 0 : value));
    function wrap(b) {
      return {
        _big: b,
        toString: function (radix) { return b.toString(radix || 10); },
        toJSNumber: function () { return Number(b); },
        valueOf: function () { return b; },
        add: function (o) { return wrap(b + BigInt(String(o && o._big !== undefined ? o._big : o))); },
        subtract: function (o) { return wrap(b - BigInt(String(o && o._big !== undefined ? o._big : o))); },
        multiply: function (o) { return wrap(b * BigInt(String(o && o._big !== undefined ? o._big : o))); },
        divide: function (o) { return wrap(b / BigInt(String(o && o._big !== undefined ? o._big : o))); },
        mod: function (o) { return wrap(b % BigInt(String(o && o._big !== undefined ? o._big : o))); },
        pow: function (o) { return wrap(b ** BigInt(String(o && o._big !== undefined ? o._big : o))); },
        isZero: function () { return b === BigInt(0); },
        isNegative: function () { return b < BigInt(0); },
        equals: function (o) { return b === BigInt(String(o && o._big !== undefined ? o._big : o)); },
        greater: function (o) { return b > BigInt(String(o && o._big !== undefined ? o._big : o)); },
        lesser: function (o) { return b < BigInt(String(o && o._big !== undefined ? o._big : o)); }
      };
    }
    return wrap(v);
  }

  // ------------------------------------------------------------------
  // CryptoJS facade backed by CommonCrypto through the native bridge
  // ------------------------------------------------------------------
  function wordArray(bytes) {
    var words = [];
    for (var i = 0; i < bytes.length; i += 4) {
      words.push(((bytes[i] << 24) | ((bytes[i + 1] || 0) << 16) |
                  ((bytes[i + 2] || 0) << 8) | (bytes[i + 3] || 0)) & 0xffffffff);
    }
    return {
      words: words,
      sigBytes: bytes.length,
      _bytes: bytes,
      toString: function (encoder) {
        if (encoder === CryptoJS.enc.Hex) {
          return bytes.map(function (b) { return (b < 16 ? "0" : "") + (b & 0xff).toString(16); }).join("");
        }
        if (encoder === CryptoJS.enc.Base64) {
          return typeof btoa === "function" ? btoa(bytesToString(bytes)) : "";
        }
        return bytesToString(bytes);
      }
    };
  }
  function toBytes(value) {
    if (value == null) { return []; }
    if (value._bytes) { return value._bytes.slice(); }
    if (typeof value === "string") { return utf8Bytes(value); }
    if (Array.isArray(value)) { return value.slice(); }
    if (typeof value.toString === "function") { return utf8Bytes(value.toString()); }
    return [];
  }
  function hashHex(algo, text, keyHex) {
    try {
      if (keyHex !== undefined) {
        return __mf_hmac__(algo, String(text), String(keyHex));
      }
      return __mf_hash__(algo, String(text));
    } catch (error) { diag("hash failed " + algo + ": " + error); return ""; }
  }
  var CryptoJS = {
    enc: {
      Hex: { _name: "Hex", stringify: function (w) { return w.toString(this); }, parse: function (s) { return wordArray(hexBytes(String(s))); } },
      Utf8: { _name: "Utf8", stringify: function (w) { return w.toString(this); }, parse: function (s) { return wordArray(utf8Bytes(String(s))); } },
      Base64: { _name: "Base64", stringify: function (w) { return w.toString(this); }, parse: function (s) { return wordArray(base64Bytes(String(s))); } }
    },
    mode: { CBC: "CBC", ECB: "ECB", CFB: "CFB", OFB: "OFB", CTR: "CTR" },
    pad: { Pkcs7: "Pkcs7", NoPadding: "NoPadding", Iso97971: "Iso97971", ZeroPadding: "ZeroPadding" },
    lib: { WordArray: function (bytes) { return wordArray(bytes || []); } },
    MD5: function (value) {
      var hex = hashHex("md5", stringsToArgs([value])[0]);
      return { toString: function (enc) { return encodeFromHex(hex, enc); }, _hex: hex };
    },
    SHA1: function (value) {
      var hex = hashHex("sha1", stringsToArgs([value])[0]);
      return { toString: function (enc) { return encodeFromHex(hex, enc); }, _hex: hex };
    },
    SHA256: function (value) {
      var hex = hashHex("sha256", stringsToArgs([value])[0]);
      return { toString: function (enc) { return encodeFromHex(hex, enc); }, _hex: hex };
    },
    SHA512: function (value) {
      var hex = hashHex("sha512", stringsToArgs([value])[0]);
      return { toString: function (enc) { return encodeFromHex(hex, enc); }, _hex: hex };
    },
    HmacMD5: function (value, key) { return hmac("md5", value, key); },
    HmacSHA1: function (value, key) { return hmac("sha1", value, key); },
    HmacSHA256: function (value, key) { return hmac("sha256", value, key); },
    AES: {
      encrypt: function (message, key, cfg) {
        cfg = cfg || {};
        var mode = cfg.mode === CryptoJS.mode.ECB ? "ECB" : "CBC";
        var padding = cfg.padding === CryptoJS.pad.NoPadding ? "NoPadding" : "Pkcs7";
        var messageBytes = toBytes(message);
        var keyBytes = toBytes(key);
        var ivBytes = cfg.iv ? toBytes(cfg.iv) : [];
        var hex = __mf_aes__("encrypt", bytesToHex(messageBytes), bytesToHex(keyBytes),
                             bytesToHex(ivBytes), mode, padding);
        return {
          ciphertext: wordArray(hexBytes(hex)),
          toString: function (enc) { return encodeFromHex(hex, enc || CryptoJS.enc.Base64); },
          _hex: hex
        };
      },
      decrypt: function (cipher, key, cfg) {
        cfg = cfg || {};
        var mode = cfg.mode === CryptoJS.mode.ECB ? "ECB" : "CBC";
        var padding = cfg.padding === CryptoJS.pad.NoPadding ? "NoPadding" : "Pkcs7";
        var inputHex = cipher && cipher._hex ? cipher._hex : bytesToHex(toBytes(cipher));
        var hex = __mf_aes__("decrypt", inputHex, bytesToHex(toBytes(key)),
                             bytesToHex(cfg.iv ? toBytes(cfg.iv) : []), mode, padding);
        return { toString: function (enc) { return encodeFromHex(hex, enc || CryptoJS.enc.Utf8); }, _hex: hex };
      }
    },
    TripleDES: { encrypt: function () { throw new Error("CryptoJS.TripleDES is not supported"); } },
    Rabbit: { encrypt: function () { throw new Error("CryptoJS.Rabbit is not supported"); } },
    RC4: function () { throw new Error("CryptoJS.RC4 is not supported"); }
  };
  function hmac(algo, value, key) {
    var args = stringsToArgs([value, key]);
    var hex = hashHex(algo, args[0], hexOf(args[1]));
    return { toString: function (enc) { return encodeFromHex(hex, enc); }, _hex: hex };
  }
  function encodeFromHex(hex, enc) {
    if (enc === CryptoJS.enc.Hex) { return hex; }
    if (enc === CryptoJS.enc.Base64) { return typeof btoa === "function" ? btoa(bytesToString(hexBytes(hex))) : ""; }
    return bytesToString(hexBytes(hex));
  }
  function hexBytes(hex) {
    var out = [];
    var s = String(hex || "");
    for (var i = 0; i + 1 < s.length; i += 2) { out.push(parseInt(s.slice(i, i + 2), 16) & 0xff); }
    return out;
  }
  function bytesToHex(bytes) {
    return bytes.map(function (b) { return (b < 16 ? "0" : "") + (b & 0xff).toString(16); }).join("");
  }
  function base64Bytes(text) {
    var raw = typeof atob === "function" ? atob(String(text)) : "";
    var out = [];
    for (var i = 0; i < raw.length; i += 1) { out.push(raw.charCodeAt(i) & 0xff); }
    return out;
  }

  // ------------------------------------------------------------------
  // axios shim backed by the native URLSession bridge
  // ------------------------------------------------------------------
  function appendParams(url, params) {
    if (!params) { return url; }
    var query = new URLSearchParamsPolyfill(params).toString();
    if (!query) { return url; }
    return url + (String(url).indexOf("?") < 0 ? "?" : "&") + query;
  }

  function axiosRequest(config) {
    config = config || {};
    return new Promise(function (resolve, reject) {
      var id = "mfhttp_" + (++timerSeq) + "_" + Math.random().toString(36).slice(2);
      var url = appendParams(String(config.url || config.uri || ""), config.params);
      var method = String(config.method || "GET").toUpperCase();
      var headers = {};
      Object.keys(config.headers || {}).forEach(function (key) {
        if (config.headers[key] !== undefined) { headers[key] = String(config.headers[key]); }
      });
      var body = config.data;
      if (body !== undefined && body !== null && typeof body === "object" &&
          !(body instanceof ArrayBuffer) && !BufferPolyfill.isBuffer(body) &&
          headers["Content-Type"] === undefined) {
        if (config.form === true) { body = qsStringify(body, ""); headers["Content-Type"] = "application/x-www-form-urlencoded"; }
        else { body = JSON.stringify(body); headers["Content-Type"] = "application/json;charset=utf-8"; }
      }
      if (BufferPolyfill.isBuffer(body)) { body = typeof btoa === "function" ? btoa(bytesToString(body._bytes)) : ""; }
      pendingHTTP[id] = { resolve: resolve, reject: reject, config: config };
      try {
        __mf_http__(JSON.stringify({
          requestId: id, url: url, method: method, headers: headers,
          body: body, binary: config.responseType === "arraybuffer" || config.responseType === "blob",
          timeout: config.timeout || 0, maxRedirects: config.maxRedirects,
          responseType: config.responseType || ""
        }));
      } catch (error) {
        delete pendingHTTP[id];
        reject(error);
      }
    });
  }

  function createAxios(defaults) {
    defaults = defaults || {};
    function axios(config) {
      var merged = {};
      Object.keys(defaults).forEach(function (k) { merged[k] = defaults[k]; });
      Object.keys(config || {}).forEach(function (k) { merged[k] = config[k]; });
      merged.headers = Object.assign({}, defaults.headers || {}, (config || {}).headers || {});
      return axiosRequest(merged);
    }
    axios.get = function (url, config) { return axios(Object.assign({}, config || {}, { url: url, method: "GET" })); };
    axios.delete = axios.get;
    axios.head = function (url, config) { return axios(Object.assign({}, config || {}, { url: url, method: "HEAD" })); };
    axios.options = function (url, config) { return axios(Object.assign({}, config || {}, { url: url, method: "OPTIONS" })); };
    axios.post = function (url, data, config) { return axios(Object.assign({}, config || {}, { url: url, method: "POST", data: data })); };
    axios.put = function (url, data, config) { return axios(Object.assign({}, config || {}, { url: url, method: "PUT", data: data })); };
    axios.patch = function (url, data, config) { return axios(Object.assign({}, config || {}, { url: url, method: "PATCH", data: data })); };
    axios.request = axios;
    axios.defaults = defaults;
    axios.interceptors = {
      request: { use: function () { return 0; }, eject: function () {} },
      response: { use: function () { return 0; }, eject: function () {} }
    };
    axios.create = function (extra) { return createAxios(Object.assign({}, defaults, extra || {})); };
    return axios;
  }

  // ------------------------------------------------------------------
  // Mini cheerio: HTML parse + CSS selector subset used by MusicFree plugins
  // ------------------------------------------------------------------
  var voidElements = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };

  function findTagEnd(text, from) {
    var quote = "";
    for (var i = from; i < text.length; i += 1) {
      var c = text[i];
      if (quote) { if (c === quote) { quote = ""; } continue; }
      if (c === '"' || c === "'") { quote = c; continue; }
      if (c === ">") { return i; }
    }
    return -1;
  }

  function parseAttributes(raw) {
    var attrs = {};
    var re = /([^\s=/>]+)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'`=<>]+)))?/g;
    var match;
    while ((match = re.exec(raw)) !== null) {
      var name = match[1].toLowerCase();
      var value = match[2] !== undefined ? match[2] : (match[3] !== undefined ? match[3] : (match[4] !== undefined ? match[4] : ""));
      attrs[name] = decodeEntities(value);
    }
    return attrs;
  }

  function parseHTML(html) {
    var root = { type: "root", name: "#root", attrs: {}, children: [], parent: null };
    var stack = [root];
    var text = String(html == null ? "" : html);
    var i = 0;
    function pushText(value, parent) {
      if (!value) { return; }
      var target = parent || stack[stack.length - 1];
      target.children.push({ type: "text", name: "#text", data: value, attrs: {}, children: [], parent: target });
    }
    while (i < text.length) {
      var lt = text.indexOf("<", i);
      if (lt < 0) { pushText(text.slice(i)); break; }
      if (lt > i) { pushText(text.slice(i, lt)); }
      if (text.substr(lt, 4).toLowerCase() === "<!--") {
        var ce = text.indexOf("-->", lt + 4);
        i = ce < 0 ? text.length : ce + 3; continue;
      }
      if (text.substr(lt, 2) === "<!") {
        var de = findTagEnd(text, lt + 2);
        i = de < 0 ? text.length : de + 1; continue;
      }
      if (text.substr(lt, 2) === "</") {
        var closeEnd = findTagEnd(text, lt + 2);
        var closeName = text.slice(lt + 2, closeEnd < 0 ? text.length : closeEnd).trim().toLowerCase();
        for (var s = stack.length - 1; s > 0; s -= 1) {
          if (stack[s].name === closeName) { stack.length = s; break; }
        }
        i = closeEnd < 0 ? text.length : closeEnd + 1; continue;
      }
      var gt = findTagEnd(text, lt + 1);
      if (gt < 0) { pushText(text.slice(lt)); break; }
      var raw = text.slice(lt + 1, gt).trim();
      var selfClose = /\/\s*$/.test(raw);
      raw = raw.replace(/\/\s*$/, "").trim();
      var m = /^([a-zA-Z][\w:.-]*)/.exec(raw);
      if (!m) { i = gt + 1; continue; }
      var name = m[1].toLowerCase();
      var node = { type: "tag", name: name, attrs: parseAttributes(raw.slice(m[1].length)),
                   children: [], parent: stack[stack.length - 1] };
      node.parent.children.push(node);
      var rawText = name === "script" || name === "style" || name === "textarea" || name === "title";
      if (!selfClose && !voidElements[name] && !rawText) { stack.push(node); }
      i = gt + 1;
      if (rawText) {
        var endTag = "</" + name + ">";
        var pos = text.toLowerCase().indexOf(endTag, i);
        if (pos >= 0) { pushText(text.slice(i, pos), node); i = pos + endTag.length; }
      }
    }
    return root;
  }

  function nodeText(node) {
    if (!node) { return ""; }
    if (node.type === "text") { return decodeEntities(node.data); }
    if (node.name === "script" || node.name === "style") { return ""; }
    var out = "";
    for (var i = 0; i < node.children.length; i += 1) { out += nodeText(node.children[i]); }
    return out;
  }

  function nodeHTML(node) {
    if (!node) { return ""; }
    if (node.type === "text") { return encodeEntities(node.data, false); }
    if (node.type === "root") { return node.children.map(nodeHTML).join(""); }
    var attrs = Object.keys(node.attrs || {}).map(function (key) {
      return " " + key + '="' + encodeEntities(node.attrs[key], true) + '"';
    }).join("");
    if (voidElements[node.name]) { return "<" + node.name + attrs + ">"; }
    return "<" + node.name + attrs + ">" + node.children.map(nodeHTML).join("") + "</" + node.name + ">";
  }

  function splitTopLevel(text, separator) {
    var out = [], depth = 0, quote = "", start = 0;
    for (var i = 0; i < text.length; i += 1) {
      var c = text[i];
      if (quote) { if (c === quote) { quote = ""; } continue; }
      if (c === '"' || c === "'") { quote = c; continue; }
      if (c === "[" || c === "(") { depth += 1; continue; }
      if (c === "]" || c === ")") { depth -= 1; continue; }
      if (c === separator && depth === 0) { out.push(text.slice(start, i)); start = i + 1; }
    }
    out.push(text.slice(start));
    return out.map(function (s) { return s.trim(); }).filter(Boolean);
  }

  function tokenizeSelector(selector) {
    var tokens = [], current = "", start = 0;
    for (var i = 0; i < selector.length; i += 1) {
      var c = selector[i];
      if (c === "[") {
        var end = selector.indexOf("]", i);
        if (end >= 0) { current += selector.slice(i, end + 1); i = end; continue; }
      }
      if (c === "(") {
        var close = selector.indexOf(")", i);
        if (close >= 0) { current += selector.slice(i, close + 1); i = close; continue; }
      }
      if (c === ">" || c === "+" || c === "~" || /\s/.test(c)) {
        if (current.trim()) { tokens.push({ kind: "descendant", value: current.trim() }); }
        current = "";
        if (c === ">") { tokens.push({ kind: "child" }); }
        else if (c === "+") { tokens.push({ kind: "next" }); }
        else if (c === "~") { tokens.push({ kind: "siblings" }); }
        continue;
      }
      current += c;
      start = i;
    }
    if (current.trim()) { tokens.push({ kind: "descendant", value: current.trim() }); }
    return tokens;
  }

  function matchCompound(node, compound) {
    if (!node || node.type !== "tag" || compound === "*") { return node && node.type === "tag" && compound === "*"; }
    var rest = compound;
    var tag = /^[a-zA-Z][\w:.-]*/.exec(rest);
    if (tag) {
      if (node.name !== tag[0].toLowerCase()) { return false; }
      rest = rest.slice(tag[0].length);
    }
    var guard = 0;
    while (rest && guard < 40) {
      guard += 1;
      var hash = /^#([\w-]+)/.exec(rest);
      if (hash) { if (node.attrs.id !== hash[1]) { return false; } rest = rest.slice(hash[0].length); continue; }
      var cls = /^\.([\w-]+)/.exec(rest);
      if (cls) {
        var classes = String(node.attrs["class"] || "").split(/\s+/);
        if (classes.indexOf(cls[1]) < 0) { return false; }
        rest = rest.slice(cls[0].length); continue;
      }
      var attr = /^\[([^\]]+)\]/.exec(rest);
      if (attr) {
        var body = attr[1];
        var op = /^([\w:.-]+)\s*(?:([*^$~!]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s\]]+)))?$/.exec(body);
        if (!op) { return false; }
        var key = op[1].toLowerCase();
        var actual = node.attrs[key];
        if (actual === undefined) { return false; }
        if (op[2]) {
          var expected = op[3] !== undefined ? op[3] : (op[4] !== undefined ? op[4] : op[5]);
          expected = expected === undefined ? "" : expected;
          if (op[2] === "=" && actual !== expected) { return false; }
          if (op[2] === "*=" && actual.indexOf(expected) < 0) { return false; }
          if (op[2] === "^=" && actual.indexOf(expected) !== 0) { return false; }
          if (op[2] === "$=" && actual.slice(-expected.length) !== expected) { return false; }
          if (op[2] === "~=" && String(actual).split(/\s+/).indexOf(expected) < 0) { return false; }
          if (op[2] === "!=" && actual === expected) { return false; }
        }
        rest = rest.slice(attr[0].length); continue;
      }
      var pseudo = /^:([\w-]+)(?:\(([^)]*)\))?/.exec(rest);
      if (pseudo) {
        var name = pseudo[1], arg = pseudo[2];
        var siblings = node.parent ? node.parent.children.filter(function (n) { return n.type === "tag"; }) : [node];
        var index = siblings.indexOf(node);
        if (name === "first-child" && index !== 0) { return false; }
        if (name === "last-child" && index !== siblings.length - 1) { return false; }
        if (name === "only-child" && siblings.length !== 1) { return false; }
        if (name === "nth-child") {
          var n = parseInt(arg, 10);
          if (!isNaN(n) && index + 1 !== n) { return false; }
          if (arg === "odd" && (index + 1) % 2 === 0) { return false; }
          if (arg === "even" && (index + 1) % 2 === 1) { return false; }
        }
        if (name === "contains" && nodeText(node).indexOf(String(arg || "")) < 0) { return false; }
        if (name === "empty" && node.children.length > 0) { return false; }
        rest = rest.slice(pseudo[0].length); continue;
      }
      return false;
    }
    return true;
  }

  function matchesSelector(node, selector) {
    var groups = splitTopLevel(selector, ",");
    for (var g = 0; g < groups.length; g += 1) {
      var tokens = tokenizeSelector(groups[g]);
      var compounds = tokens.filter(function (t) { return t.kind === "descendant"; });
      if (!compounds.length || !matchCompound(node, compounds[compounds.length - 1].value)) { continue; }
      var cursor = node;
      var ok = true;
      for (var i = compounds.length - 2; i >= 0 && cursor; i -= 1) {
        var combinator = tokens[tokens.indexOf(compounds[i + 1]) - 1];
        var compound = compounds[i].value;
        var found = null;
        if (combinator && combinator.kind === "child") {
          found = cursor.parent && matchCompound(cursor.parent, compound) ? cursor.parent : null;
        } else if (combinator && (combinator.kind === "next" || combinator.kind === "siblings")) {
          var sib = previousSiblings(cursor);
          for (var s = 0; s < sib.length; s += 1) {
            if (matchCompound(sib[s], compound)) { found = sib[s]; break; }
          }
          if (combinator.kind === "next" && sib.length && found !== sib[0]) { found = null; }
        } else {
          var ancestor = cursor.parent;
          while (ancestor) {
            if (matchCompound(ancestor, compound)) { found = ancestor; break; }
            ancestor = ancestor.parent;
          }
        }
        if (!found) { ok = false; break; }
        cursor = found;
      }
      if (ok) { return true; }
    }
    return false;
  }

  function previousSiblings(node) {
    if (!node || !node.parent) { return []; }
    var out = [];
    for (var i = 0; i < node.parent.children.length; i += 1) {
      if (node.parent.children[i] === node) { break; }
      if (node.parent.children[i].type === "tag") { out.push(node.parent.children[i]); }
    }
    return out.reverse();
  }

  function walk(node, fn) {
    if (!node) { return; }
    for (var i = 0; i < node.children.length; i += 1) {
      var child = node.children[i];
      if (child.type === "tag") { fn(child); }
      walk(child, fn);
    }
  }

  function Selection(nodes, root) {
    this.length = nodes.length;
    this._nodes = nodes;
    this._root = root || null;
    var self = this;
    this.get = function (i) { return self._nodes[i < 0 ? self._nodes.length + i : i]; };
    this.eq = function (i) { var n = self.get(i); return new Selection(n ? [n] : [], self._root); };
    this.first = function () { return self.eq(0); };
    this.last = function () { return self.eq(-1); };
    this.toArray = function () { return self._nodes.slice(); };
    this.each = function (fn) { self._nodes.forEach(function (n, i) { fn.call(n, i, n); }); return self; };
    this.map = function (fn) {
      var out = [];
      self._nodes.forEach(function (n, i) {
        var value = fn.call(n, i, n);
        if (value === undefined || value === null) { return; }
        if (Array.isArray(value)) { out = out.concat(value); } else { out.push(value); }
      });
      return new Selection(out.map(function (v) { return v && v.nodeType !== undefined ? v : v; }), self._root);
    };
    this.text = function (value) {
      if (value !== undefined) {
        self._nodes.forEach(function (n) { n.children = [{ type: "text", name: "#text", data: String(value), attrs: {}, children: [], parent: n }]; });
        return self;
      }
      return self._nodes.map(nodeText).join("");
    };
    this.html = function (value) {
      if (value !== undefined) {
        self._nodes.forEach(function (n) { n.children = parseHTML(String(value)).children; });
        return self;
      }
      return self._nodes.length ? nodeHTML(self._nodes[0]) : null;
    };
    this.attr = function (name, value) {
      if (value === undefined) { return self._nodes.length ? self._nodes[0].attrs[name] : undefined; }
      self._nodes.forEach(function (n) { n.attrs[name] = String(value); });
      return self;
    };
    this.removeAttr = function (name) { self._nodes.forEach(function (n) { delete n.attrs[name]; }); return self; };
    this.hasClass = function (name) { return self._nodes.some(function (n) { return String(n.attrs["class"] || "").split(/\s+/).indexOf(name) >= 0; }); };
    this.is = function (selector) { return self._nodes.some(function (n) { return matchesSelector(n, selector); }); };
    this.filter = function (selector) {
      return new Selection(self._nodes.filter(function (n) { return typeof selector === "function" ? selector.call(n, n) : matchesSelector(n, selector); }), self._root);
    };
    this.not = function (selector) {
      return new Selection(self._nodes.filter(function (n) { return !matchesSelector(n, selector); }), self._root);
    };
    this.find = function (selector) {
      var out = [];
      self._nodes.forEach(function (n) { walk(n, function (child) { if (matchesSelector(child, selector)) { out.push(child); } }); });
      return new Selection(out, self._root);
    };
    this.children = function (selector) {
      var out = [];
      self._nodes.forEach(function (n) {
        n.children.forEach(function (child) {
          if (child.type === "tag" && (!selector || matchesSelector(child, selector))) { out.push(child); }
        });
      });
      return new Selection(out, self._root);
    };
    this.contents = function () {
      var out = [];
      self._nodes.forEach(function (n) { out = out.concat(n.children); });
      return new Selection(out.map(function (n) { return n.type === "tag" ? n : n; }), self._root);
    };
    this.parent = function (selector) {
      var out = [];
      self._nodes.forEach(function (n) { if (n.parent && n.parent.type === "tag" && (!selector || matchesSelector(n.parent, selector))) { out.push(n.parent); } });
      return new Selection(out, self._root);
    };
    this.closest = function (selector) {
      var out = [];
      self._nodes.forEach(function (n) {
        var cursor = n;
        while (cursor && cursor.type === "tag") {
          if (matchesSelector(cursor, selector)) { out.push(cursor); break; }
          cursor = cursor.parent;
        }
      });
      return new Selection(out, self._root);
    };
    this.next = function () {
      var out = [];
      self._nodes.forEach(function (n) {
        if (!n.parent) { return; }
        var seen = false;
        n.parent.children.forEach(function (child) {
          if (child === n) { seen = true; return; }
          if (seen && child.type === "tag") { out.push(child); seen = false; }
        });
      });
      return new Selection(out, self._root);
    };
    this.prev = function () {
      var out = [];
      self._nodes.forEach(function (n) { var p = previousSiblings(n); if (p.length) { out.push(p[0]); } });
      return new Selection(out, self._root);
    };
    this.siblings = function (selector) {
      var out = [];
      self._nodes.forEach(function (n) {
        if (!n.parent) { return; }
        n.parent.children.forEach(function (child) {
          if (child !== n && child.type === "tag" && (!selector || matchesSelector(child, selector))) { out.push(child); }
        });
      });
      return new Selection(out, self._root);
    };
    this.remove = function () {
      self._nodes.forEach(function (n) {
        if (!n.parent) { return; }
        var at = n.parent.children.indexOf(n);
        if (at >= 0) { n.parent.children.splice(at, 1); }
      });
      return self;
    };
    this.index = function () {
      if (!self._nodes.length || !self._nodes[0].parent) { return -1; }
      return self._nodes[0].parent.children.indexOf(self._nodes[0]);
    };
    this.add = function (other) { return new Selection(self._nodes.concat(other._nodes || []), self._root); };
  }

  function cheerioLoad(content) {
    var root = parseHTML(content);
    function select(selector, context) {
      if (!selector) { return new Selection([], root); }
      if (typeof selector === "object" && selector._nodes) { return new Selection(selector._nodes, root); }
      if (selector.type === "tag") { return new Selection([selector], root); }
      if (String(selector).charAt(0) === "<") {
        return new Selection(parseHTML(String(selector)).children.filter(function (n) { return n.type === "tag"; }), root);
      }
      var out = [];
      var scope = context && context._nodes ? context._nodes : [root];
      scope.forEach(function (node) {
        if (matchesSelector(node, String(selector))) { out.push(node); }
        walk(node, function (child) { if (matchesSelector(child, String(selector))) { out.push(child); } });
      });
      return new Selection(out, root);
    }
    select.root = function () { return new Selection([root], root); };
    select.html = function () { return nodeHTML(root); };
    select.text = function () { return nodeText(root); };
    select.contains = function (a, b) { return a === b || (a.children || []).indexOf(b) >= 0; };
    return select;
  }

  // ------------------------------------------------------------------
  // env / user variables
  // ------------------------------------------------------------------
  function getUserVariables() {
    if (userVariables !== null) { return userVariables; }
    var raw = "";
    try { raw = __mf_get_var__(pluginID) || "{}"; } catch (error) { raw = "{}"; }
    userVariables = parseJSON(raw, {}) || {};
    return userVariables;
  }
  var envModule = {
    getUserVariables: getUserVariables,
    getUserVariable: function (key) { return getUserVariables()[key]; }
  };

  // ------------------------------------------------------------------
  // Native callbacks
  // ------------------------------------------------------------------
  function handleHTTPResponse(payload) {
    var entry = pendingHTTP[payload.requestId];
    if (!entry) { return; }
    delete pendingHTTP[payload.requestId];
    if (payload.error) { entry.reject(new Error(payload.error)); return; }
    var config = entry.config || {};
    var data = payload.data;
    if (config.responseType === "arraybuffer" && typeof data === "string") {
      try {
        var bytes = __mf_b642ab__(data);
        var buffer = new ArrayBuffer(bytes.length);
        new Uint8Array(buffer).set(bytes);
        data = buffer;
      } catch (error) { data = data; }
    }
    entry.resolve({
      data: data,
      status: payload.status || 0,
      statusText: payload.statusText || "",
      headers: payload.headers || {},
      config: config,
      request: null
    });
  }

  function handleTimer(payload) {
    var entry = pendingTimers[payload.timerId];
    if (!entry) { return; }
    if (!entry.interval) { delete pendingTimers[payload.timerId]; }
    try { entry.fn.apply(null, entry.args || []); } catch (error) { diag("timer callback error: " + error); }
  }

  function setTimeoutPolyfill(fn, delay) {
    var id = "mft_" + (++timerSeq);
    var args = Array.prototype.slice.call(arguments, 2);
    pendingTimers[id] = { fn: fn, args: args, interval: false };
    try { __mf_set_timeout__(id, Math.max(0, Number(delay) || 0)); }
    catch (error) { delete pendingTimers[id]; }
    return id;
  }
  function clearTimeoutPolyfill(id) {
    if (!pendingTimers[id]) { return; }
    delete pendingTimers[id];
    try { __mf_clear_timeout__(id); } catch (error) {}
  }
  function setIntervalPolyfill(fn, delay) {
    var id = "mfi_" + (++timerSeq);
    var args = Array.prototype.slice.call(arguments, 2);
    pendingTimers[id] = { fn: fn, args: args, interval: true };
    try { __mf_set_interval__(id, Math.max(16, Number(delay) || 16)); }
    catch (error) { delete pendingTimers[id]; }
    return id;
  }
  function clearIntervalPolyfill(id) { clearTimeoutPolyfill(id); }

  // ------------------------------------------------------------------
  // CommonJS loader
  // ------------------------------------------------------------------
  var moduleCache = {};
  function builtinRequire(name) {
    switch (name) {
      case "axios": return createAxios({});
      case "cheerio": return { load: cheerioLoad, default: { load: cheerioLoad } };
      case "crypto-js": return CryptoJS;
      case "dayjs": return dayjs;
      case "he": return heModule;
      case "qs": return qsModule;
      case "big-integer": return bigInteger;
      case "url": return { URL: URLPolyfill, URLSearchParams: URLSearchParamsPolyfill };
      case "buffer": return { Buffer: BufferPolyfill };
      case "path": return {
        basename: function (p) { return String(p || "").split(/[\\/]/).pop(); },
        dirname: function (p) { var s = String(p || ""); var at = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\")); return at < 0 ? "." : s.slice(0, at); },
        join: function () { return Array.prototype.slice.call(arguments).join("/").replace(/\/+/g, "/"); },
        extname: function (p) { var s = String(p || ""); var at = s.lastIndexOf("."); return at < 0 ? "" : s.slice(at); }
      };
      case "lodash.shuffle": return function (list) { var a = list.slice(); for (var i = a.length - 1; i > 0; i -= 1) { var j = Math.floor(Math.random() * (i + 1)); var t = a[i]; a[i] = a[j]; a[j] = t; } return a; };
      default: return undefined;
    }
  }

  function makeRequire() {
    function requireFn(name) {
      if (moduleCache[name] !== undefined) { return moduleCache[name]; }
      var value = builtinRequire(name);
      if (value === undefined) {
        throw new Error("MusicFree: unsupported module '" + name + "'");
      }
      // Babel/TypeScript output accesses `axios_1.default.get`. Expose both.
      if (name === "axios") { value.default = value; }
      if (name === "dayjs") { value.default = value; }
      if (name === "big-integer") { value.default = value; }
      moduleCache[name] = value;
      return value;
    }
    requireFn.resolve = function (name) { return name; };
    requireFn.cache = moduleCache;
    requireFn.main = null;
    return requireFn;
  }

  function evaluatePlugin(script, id) {
    var module = { exports: {} };
    var exports = module.exports;
    var requireFn = makeRequire();
    var factory = new Function("module", "exports", "require", "globalThis", "process", "Buffer",
      "URL", "URLSearchParams", "setTimeout", "clearTimeout", "setInterval", "clearInterval",
      String(script) + "\n//# sourceURL=musicfree-plugin://" + id);
    factory(module, exports, requireFn, globalThis,
            { env: {}, version: "1.0.0", platform: "ios" },
            BufferPolyfill, URLPolyfill, URLSearchParamsPolyfill,
            setTimeoutPolyfill, clearTimeoutPolyfill, setIntervalPolyfill, clearIntervalPolyfill);
    var result = module.exports;
    if (result && result.__esModule && result.default) { result = result.default; }
    return result || {};
  }

  // ------------------------------------------------------------------
  // Plugin method invocation
  // ------------------------------------------------------------------
  function musicItemFromInfo(info) {
    info = info || {};
    var legacy = info.musicInfo || {};
    var item = parseJSON(legacy.mfItem, null) || {};
    if (typeof item !== "object" || item === null) { item = {}; }
    if (!item.id) { item.id = legacy.songmid || legacy.songId || legacy.hash || legacy.id || ""; }
    if (!item.title) { item.title = legacy.name || ""; }
    if (!item.artist) { item.artist = legacy.singer || ""; }
    if (!item.album) { item.album = legacy.albumName || ""; }
    if (!item.artwork) { item.artwork = legacy.img || ""; }
    if (!item.duration) {
      var parts = String(legacy.interval || "").split(":");
      if (parts.length === 2) { item.duration = parseInt(parts[0], 10) * 60 + parseInt(parts[1], 10); }
    }
    if (!item.source) { item.source = legacy.source || info.source || pluginPlatform; }
    if (!item.qualities) { item.qualities = {}; }
    item.$(pluginPlatform) = item.$(pluginPlatform) || item;
    return item;
  }

  function lxQualityToMF(token) {
    switch (String(token || "").toLowerCase()) {
      case "128k": case "standard": return "standard";
      case "320k": case "higher": case "exhigh": case "high": return "high";
      case "flac": case "lossless": return "super";
      case "flac24bit": case "hires": case "master": case "jymaster": return "super";
      default: return "standard";
    }
  }

  function invoke(method, args) {
    if (!plugin || typeof plugin[method] !== "function") {
      return Promise.reject(new Error("插件未提供 " + method + " 接口"));
    }
    try {
      return Promise.resolve(plugin[method].apply(plugin, args));
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function handleMusicURL(requestKey, info) {
    var item = musicItemFromInfo(info);
    var quality = lxQualityToMF(info.type);
    invoke("getMediaSource", [item, quality]).then(function (result) {
      if (!result || !result.url) { respond(requestKey, { data: {} }, "插件没有返回播放地址"); return; }
      respond(requestKey, { data: { url: String(result.url), type: result.quality || quality } });
    }).catch(function (error) {
      respond(requestKey, { data: {} }, String(error && error.message ? error.message : error));
    });
  }

  function handleLyric(requestKey, info) {
    var item = musicItemFromInfo(info);
    invoke("getLyric", [item]).then(function (result) {
      if (!result) { respond(requestKey, { data: {} }, "插件没有返回歌词"); return; }
      if (typeof result === "string") { respond(requestKey, { data: result }); return; }
      var lyric = result.rawLrc || result.lyric || result.lrc || "";
      var payload = { lyric: lyric };
      if (result.tlyric) { payload.tlyric = result.tlyric; }
      if (result.translateLrc) { payload.tlyric = result.translateLrc; }
      respond(requestKey, { data: payload });
    }).catch(function (error) {
      respond(requestKey, { data: {} }, String(error && error.message ? error.message : error));
    });
  }

  function handleRequest(action, json) {
    var payload = parseJSON(json, {}) || {};
    var requestKey = payload.requestKey;
    var detail = payload.data || {};
    var kind = detail.action;
    var info = detail.info || {};
    if (kind === "musicUrl") { handleMusicURL(requestKey, info); return; }
    if (kind === "lyric") { handleLyric(requestKey, info); return; }
    respond(requestKey, { data: {} }, "MusicFree 插件不支持操作 " + kind);
  }

  function handlePluginInvoke(action, json) {
    var payload = parseJSON(json, {}) || {};
    var requestKey = payload.requestKey;
    var method = payload.method;
    var args = payload.args || [];
    invoke(method, args).then(function (result) {
      var payload = { platform: pluginPlatform };
      if (result && typeof result === "object" && !Array.isArray(result)) {
        Object.keys(result).forEach(function (key) { payload[key] = result[key]; });
      } else {
        payload.data = result;
      }
      respond(requestKey, { result: payload });
    }).catch(function (error) {
      respond(requestKey, {}, String(error && error.message ? error.message : error));
    });
  }

  // Native -> JS entry point. LX uses the same function name so the untouched
  // LXUserAPIService.callJS() works for both protocols.
  globalThis.__lx_native__ = function (key, action, json) {
    if (hostKey && key !== hostKey) { return; }
    if (action === "request") { handleRequest(action, json); return; }
    if (action === "pluginInvoke") { handlePluginInvoke(action, json); return; }
    if (action === "__mf_http_response__") { handleHTTPResponse(parseJSON(json, {}) || {}); return; }
    if (action === "__mf_timer__") { handleTimer(parseJSON(json, {}) || {}); return; }
    if (action === "cancelRequest") { return; }
  };

  // ------------------------------------------------------------------
  // Setup: same signature as lx_setup so the native loader is shared.
  // ------------------------------------------------------------------
  globalThis.mf_setup = function (key, id, name, description, version, author, homepage, script) {
    hostKey = String(key || "");
    pluginID = String(id || "");
    try {
      plugin = evaluatePlugin(String(script || ""), pluginID);
    } catch (error) {
      native("init", { status: false, errorMessage: "插件脚本执行失败：" + (error && error.message ? error.message : error) });
      diag("plugin evaluate failed: " + error);
      return;
    }
    pluginPlatform = String(plugin.platform || pluginPlatform);
    var methods = ["search", "getMediaSource", "getLyric"];
    var found = methods.filter(function (method) { return typeof plugin[method] === "function"; });
    diag("loaded " + pluginPlatform + " methods=" + found.join(","));
    var sources = {};
    var names = [pluginPlatform, "wy", "kw", "kg", "tx", "mg"];
    names.forEach(function (item) {
      if (!item) { return; }
      sources[item] = { actions: found.indexOf("getMediaSource") >= 0 ? ["musicUrl", "lyric"] : ["lyric"],
                        qualitys: ["128k", "320k", "flac"] };
    });
    native("init", { status: true, info: { sources: sources } });
  };
})();
