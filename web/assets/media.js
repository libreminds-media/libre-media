/* libre-media — shared helpers for index.html and album.html. */

(function (global) {
  "use strict";

  var CFG = global.LIBRE_MEDIA || {};
  var MEDIA_BASE = CFG.MEDIA_BASE || "/media/";

  /* Resolve a manifest-relative path to a URL the browser can fetch.
   *
   *   mediaUrl("events/2025-test/", "thumb/ab12.webp")
   *     -> "/media/events/2025-test/thumb/ab12.webp"
   *
   * Absolute URLs pass through untouched: YouTube items carry real
   * https://i.ytimg.com/... thumbnails that must NOT be sent through the
   * B2 cache proxy. */
  function mediaUrl(base, rel) {
    if (!rel) return "";
    if (/^(https?:)?\/\//i.test(rel)) return rel;
    return MEDIA_BASE + (base || "") + rel;
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function formatDate(iso) {
    if (!iso) return "";
    var d = new Date(iso + "T00:00:00Z");
    if (isNaN(d)) return iso;
    return d.toLocaleDateString(undefined, {
      year: "numeric", month: "long", day: "numeric", timeZone: "UTC",
    });
  }

  function plural(n, one, many) {
    return n + " " + (n === 1 ? one : many);
  }

  async function getJSON(url) {
    var res = await fetch(url, { cache: "no-cache" });
    if (!res.ok) throw new Error(res.status + " " + res.statusText + " for " + url);
    return res.json();
  }

  global.LM = { mediaUrl: mediaUrl, esc: esc, formatDate: formatDate,
                plural: plural, getJSON: getJSON, CFG: CFG };
})(window);
