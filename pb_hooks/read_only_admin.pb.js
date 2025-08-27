/// <reference path="../pb_data/types.d.ts" />
/**
 * Read-only schema guard (always enabled).
 * Blocks schema/admin/settings mutations but allows record CRUD.
 * Works on PocketBase 0.22.x with JS hooks.
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
      const method = (ctx.request?.method || "").toUpperCase();
      if (method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE") {
        const path =
          ctx.request?.path ||
          ctx.request?.url?.pathname ||
          ctx.request?.url?.path ||
          "";

        // Allow all record operations (add/edit/delete rows)
        if (allowRecords.test(path)) {
          return ctx.next();
        }

        // Block schema/admin/settings writes
        for (const rx of blocked) {
          if (rx.test(path)) {
            ctx.response.status = 403;
            return ctx.response.json({
              code: "read_only_admin",
              message: "Schema/config changes are disabled in this environment."
            });
          }
        }
      }
    } catch (err) {
      // Never break server startup on hook errors
      try { console.log("[read-only-admin] middleware error:", err && (err.message || err)); } catch (_) {}
    }
    return ctx.next();
  });

  try { console.log("[read-only-admin] enabled (env-free)"); } catch (_) {}
})();
