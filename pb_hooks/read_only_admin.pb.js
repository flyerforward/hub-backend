/// <reference path="../pb_data/types.d.ts" />
/**
 * Read-only schema guard for production.
 * Set PB_READONLY_ADMIN=true to enable.
 * Blocks schema/admin/settings mutations but allows record CRUD.
 */

(() => {
  const enabled = (env("PB_READONLY_ADMIN") || "").toLowerCase() === "true";
  if (!enabled) {
    console.log("[read-only-admin] disabled");
    return;
  }

  // Anything under /api/collections/{name}/records is allowed (CRUD rows)
  const allowRecords = /^\/api\/collections\/[^/]+\/records(\/|$)/i;

  // Endpoints that mutate schema/admin/settings (block these)
  const blocked = [
    /^\/api\/collections\/?$/i,                         // POST create collection
    /^\/api\/collections\/[^/]+$/i,                     // PATCH/DELETE a collection
    /^\/api\/collections\/(import|export|truncate)(\/|$)/i,
    /^\/api\/settings$/i,                               // PATCH settings
    /^\/api\/admins(\/|$)/i,                            // admin management
    /^\/api\/logs(\/|$)/i                               // defensive
  ];

  routerUse((e) => {
    try {
      const m = (e.request?.method || "").toUpperCase();
      if (m === "POST" || m === "PUT" || m === "PATCH" || m === "DELETE") {
        const p = e.request?.path || e.request?.url?.path || e.request?.url?.pathname || "";

        // Allow normal record operations
        if (allowRecords.test(p)) {
          return e.next();
        }

        // Block schema/admin/settings writes
        for (let rx of blocked) {
          if (rx.test(p)) {
            return e.json(403, {
              code: "read_only_admin",
              message: "Schema/config changes are disabled in this environment."
            });
          }
        }
      }
    } catch (err) {
      // Never break server startup on hook errors
      console.log("[read-only-admin] middleware error:", err && (err.message || err));
    }
    return e.next();
  });

  console.log("[read-only-admin] enabled");
})();
