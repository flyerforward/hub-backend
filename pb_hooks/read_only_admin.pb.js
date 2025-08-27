/// <reference path="../pb_data/types.d.ts" />
/**
 * Production "read-only admin" guard.
 * - Allows normal record CRUD: /api/collections/<name>/records...
 * - Blocks schema/admin/settings/logs mutations that would create migrations or change config.
 */

onBeforeServe(({ router /*, db, app */ }) => {
  // Allow normal record CRUD under /api/collections/<name>/records...
  const allowRecords = /^\/api\/collections\/[^/]+\/records(?:\/|$)/i;

  // Block schema/admin/settings mutations (be slightly over-inclusive on /api/collections/*)
  const blocked = [
    // collection schema ops (create/update/delete/import/export/truncate, etc.)
    /^\/api\/collections(?:\/(?![^/]+\/records)(?:.*))?$/i,
    /^\/api\/collections\/(import|export|truncate)(?:\/|$)/i,

    // settings & admins management
    /^\/api\/settings(?:\/|$)/i,
    /^\/api\/admins(?:\/|$)/i,

    // optional: logs writes/cleanups (defensive)
    /^\/api\/logs(?:\/|$)/i,
  ];

  router.use((c, next) => {
    try {
      const method = String(c?.request?.method || "").toUpperCase();

      // Only police mutating verbs
      if (method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE") {
        const path =
          c?.request?.path ??
          c?.request?.url?.pathname ??
          c?.request?.url?.path ??
          "";

        // Explicitly allow record CRUD
        if (allowRecords.test(path)) {
          return next();
        }

        // Block schema/admin/settings writes
        for (const rx of blocked) {
          if (rx.test(path)) {
            return c.json(403, {
              code: "read_only_admin",
              message: "Schema/config changes are disabled in this environment.",
            });
          }
        }
      }

      // Everything else passes through (e.g., GET /api/health)
      return next();
    } catch (err) {
      // Never break the router stack on errors
      try { console.log("[read-only-admin] middleware error:", err && (err.message || err)); } catch (_) {}
      return next();
    }
  });

  try { console.log("[read-only-admin] enabled"); } catch (_) {}
});
