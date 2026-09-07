/* libre-media — front-end configuration.
 *
 * Tracked in git and MUST NOT contain secrets (CLAUDE.md §5).
 *
 * ---------------------------------------------------------------------------
 * URL CONTRACT (shared with cache/nginx.conf.template)
 *
 *     /media/<key>  ->  https://<B2_DOWNLOAD_HOST>/file/<B2_BUCKET>/<key>
 *
 * Album manifests store paths relative to their own `base` ("events/<slug>/"),
 * so a manifest entry "thumb/ab12cd34ef56.webp" in album 2025-test resolves to
 *
 *     /media/events/2025-test/thumb/ab12cd34ef56.webp
 *
 * Caddy routes /media/* to the `cache` container; everything else goes to
 * `web`. Change MEDIA_BASE here and you must change the rewrite in
 * cache/nginx.conf.template to match.
 * ---------------------------------------------------------------------------
 */
window.LIBRE_MEDIA = {
  /* Prefix for every media byte. Trailing slash required. */
  MEDIA_BASE: "/media/",

  /* lightGallery v2 is GPLv3 and this repository is public under a compatible
   * licence, so the GPL placeholder key is the correct value and the console
   * notice it prints is expected. LG_LICENSE_KEY in .env is a hook for a
   * future commercial licence; it is not wired up (see MIGRATE.md "Known gaps"). */
  LG_LICENSE_KEY: "0000-0000-000-0000",

  SITE_NAME: "LibreMinds",
};
