/// <reference path="../pb_data/types.d.ts" />
/* global onBeforeServe, routerUse */

/**
 * Global, hoisted middleware so loaders that call by name won't crash.
 * - Allows record CRUD: /api/collections/<name>/records...
 * - Blocks schema/admin/settings/logs writes (schema changes, imports/exports, etc.).
 */
function guardMiddleware(c, next) {
  try {
    const method = String(c?.request?.method || "").toUpperCase();

    // Only police mutating verbs
    if (method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE") {
      const path =
        c?.request?.path ??
        c?.request?.url?.pathname ??
        c?.request?.url?.path ??
        "";

      // allow normal record CRUD under /api/collections/<name>/records...
      const allowRecords = /^\/api\/collections\/[^/]+\/records(?:\/|$)/i;

      // block schema/admin/settings mutations (anything under collections that isn't .../records)
      const blocked = [
        /^\/api\/collections(?:\/(?![^/]+\/records)(?:.*))?$/i,
        /^\/api\/collections\/(import|export|truncate)(?:\/|$)/i,
        /^\/api\/settings(?:\/|$)/i,
        /^\/api\/admins(?:\/|$)/i,
        /^\/api\/logs(?:\/|$)/i,
      ];

      if (allowRecords.test(path)) {
        return next();
      }

      for (const rx of blocked) {
        if (rx.test(path)) {
          const payload = {
            code: "read_only_admin",
            message: "Schema/config changes are disabled in this environment.",
          };

          // Try both common signatures (Hono uses c.json(body, status))
          if (typeof c?.json === "function") {
            try { return c.json(payload, 403); } catch (_) {}
            try { return c.json(403, payload); } catch (_) {}
          }
          if (c?.response) {
            try { c.response.status = 403; } catch (_) {}
          }
          return payload; // last-resort return; don't explode the stack
        }
      }
    }
  } catch (err) {
    try { console.log("[read-only-admin] middleware error:", err && (err.message || err)); } catch (_) {}
  }
  return next(); // IMPORTANT: always continue for non-blocked routes (keeps /api/health OK)
}

// Auto-register in whichever environment is available
(function register() {
  if (typeof onBeforeServe === "function") {
    try {
      onBeforeServe(({ router }) => {
        router.use(guardMiddleware);
        try { console.log("[read-only-admin] enabled via onBeforeServe"); } catch (_) {}
      });
    } catch (_) { /* ignore and fall back */ }
  }
  if (typeof routerUse === "function") {
    try {
      routerUse(guardMiddleware); // some loaders call by name; we’ve defined a global
      try { console.log("[read-only-admin] enabled via routerUse"); } catch (_) {}
    } catch (_) { /* ignore */ }
  }
})(); 
