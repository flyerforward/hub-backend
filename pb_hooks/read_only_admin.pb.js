/// <reference path="../pb_data/types.d.ts" />
/**
 * Read-only schema guard (env-free, defensive).
 * Blocks schema/admin/settings mutations; allows record CRUD.
 * Works even if the JS ctx lacks `next()`.
 */

(() => {
  // Allow normal record CRUD under /api/collections/<name>/records...
  const allowRecords = /^\/api\/collections\/[^/]+\/records(\/|$)/i;

  // Block schema/admin/settings mutations
  const blocked = [
    /^\/api\/collections\/?$/i,                         // POST create collection
    /^\/api\/collections\/[^/]+$/i,                     // PATCH/DELETE a collection
    /^\/api\/collections\/(import|export|truncate)(\/|$)/i,
    /^\/api\/settings$/i,                               // PATCH settings
    /^\/api\/admins(\/|$)/i,                            // admin management
    /^\/api\/logs(\/|$)/i                               // defensive
  ];

  routerUse((ctx) => {
    try {
      const method = String(ctx?.request?.method || "").toUpperCase();
      if (method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE") {
        const path =
          ctx?.request?.path ??
          ctx?.request?.url?.pathname ??
          ctx?.request?.url?.path ??
          "";

        // Allow record operations (add/edit/delete rows)
        if (allowRecords.test(path)) {
          // pass-through without assuming next()
          if (typeof ctx?.next === "function") return ctx.next();
          return;
        }

        // Block schema/admin/settings writes
        for (const rx of blocked) {
          if (rx.test(path)) {
            if (ctx?.response) {
              ctx.response.status = 403;
              if (typeof ctx?.response?.json === "function") {
                return ctx.response.json({
                  code: "read_only_admin",
                  message: "Schema/config changes are disabled in this environment."
                });
              }
            }
            // Fallback: no response helpers; do nothing (PB will default to 403-less, but at least we won't crash)
            return;
          }
        }
      }
    } catch (err) {
      try { console.log("[read-only-admin] middleware error:", err && (err.message || err)); } catch (_) {}
    }

    // Non-mutating or non-blocked routes: pass-through (if possible)
    if (typeof ctx?.next === "function") return ctx.next();
    return;
  });

  try { console.log("[read-only-admin] enabled (defensive)"); } catch (_) {}
})();
