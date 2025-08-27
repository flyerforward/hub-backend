/// <reference path="../pb_data/types.d.ts" />
/**
 * Read-only schema guard for production.
 * Set PB_READONLY_ADMIN=true to enable.
 * Blocks schema/admin/settings mutations but allows record CRUD.
 */

onBeforeServe((e) => {
  const enabled = (env("PB_READONLY_ADMIN") || "").toLowerCase() === "true";
  if (!enabled) return;

  const blocked = [
    /^\/api\/collections\/?$/i,                       // POST create collection
    /^\/api\/collections\/[^/]+$/i,                   // PATCH/DELETE collection
    /^\/api\/collections\/(import|export|truncate)(\/|$)/i,
    /^\/api\/settings$/i,                             // PATCH settings
    /^\/api\/admins(\/|$)/i,                          // admin mgmt
    /^\/api\/logs(\/|$)/i,                            // defensive
  ];

  const allowRecordsPrefix = /^\/api\/collections\/[^/]+\/records(\/|$)/i;

  e.router.use((c) => {
    try {
      const method = c?.request?.method || "";
      if (method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE") {
        const path = c?.request?.path || "";

        // allow record CRUD
        if (allowRecordsPrefix.test(path)) {
          return c.next();
        }

        // block schema/admin/settings mutations
        for (let i = 0; i < blocked.length; i++) {
          if (blocked[i].test(path)) {
            c.response.status = 403;
            return c.response.json({
              code: "read_only_admin",
              message: "Schema/config changes are disabled in production.",
            });
          }
        }
      }
    } catch (err) {
      // Never crash startup due to hook errors
      console.log("[read-only-admin] middleware error:", err?.message || err);
    }
    return c.next();
  });

  console.log("[read-only-admin] enabled");
});
