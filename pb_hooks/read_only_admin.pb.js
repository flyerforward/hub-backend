/// <reference path="../pb_data/types.d.ts" />
/**
 * Universal read-only admin guard for production.
 * - Allows record CRUD at /api/collections/<name>/records...
 * - Blocks schema/admin/settings/admins/logs writes (things that create migrations or change config).
 * - Works in both pb_hooks (onBeforeServe) and entrypoint (routerUse) environments.
 */

(() => {
  const allowRecords = /^\/api\/collections\/[^/]+\/records(?:\/|$)/i;

  // Block any collections routes that aren't records CRUD, plus settings/admins/logs writes.
  const blocked = [
    /^\/api\/collections(?:\/(?![^/]+\/records)(?:.*))?$/i,
    /^\/api\/collections\/(import|export|truncate)(?:\/|$)/i,
    /^\/api\/settings(?:\/|$)/i,
    /^\/api\/admins(?:\/|$)/i,
    /^\/api\/logs(?:\/|$)/i,
  ];

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

        // Explicit allow for record CRUD
        if (allowRecords.test(path)) {
          return next();
        }

        // Block schema/admin/settings writes
        for (const rx of blocked) {
          if (rx.test(path)) {
            const payload = {
              code: "read_only_admin",
              message: "Schema/config changes are disabled in this environment.",
            };

            // Try both common json signatures for maximum compatibility
            if (typeof c?.json === "function") {
              try { return c.json(payload, 403); } catch (_) {}
              try { return c.json(403, payload); } catch (_) {}
            }
            if (c?.response) {
              try { c.response.status = 403; } catch (_) {}
            }
            return payload; // last-resort return (prevents router crash)
          }
        }
      }
    } catch (err) {
      try { console.log("[read-only-admin] middleware error:", err && (err.message || err)); } catch (_) {}
      // fall through to next
    }
    return next(); // IMPORTANT: keep /api/health and other routes flowing
  }

  function installWithRouterUse(routerUseFn) {
    routerUseFn((c, next) => guardMiddleware(c, next));
    try { console.log("[read-only-admin] enabled via routerUse"); } catch (_) {}
  }

  function installWithOnBeforeServe() {
    onBeforeServe?.(({ router }) => {
      router.use((c, next) => guardMiddleware(c, next));
      try { console.log("[read-only-admin] enabled via onBeforeServe"); } catch (_) {}
    });
  }

  // Auto-detect environment
  if (typeof onBeforeServe === "function") {
    installWithOnBeforeServe();
  } else if (typeof routerUse === "function") {
    installWithRouterUse(routerUse);
  } else {
    try { console.log("[read-only-admin] skipped: no onBeforeServe or routerUse in this context"); } catch (_) {}
  }
})();
