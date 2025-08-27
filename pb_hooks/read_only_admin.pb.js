/// <reference path="../pb_data/types.d.ts" />
/* global onBeforeServe, routerUse */

/**
 * Read-only admin guard for production.
 * - Allows record CRUD: /api/collections/<name>/records...
 * - Blocks schema/admin/settings/logs writes (schema changes, import/export, etc.).
 * - Safe across pb_hooks and entrypoint loaders (with or without `next`).
 */

// Safe "next" invoker for mixed environments
function _safeNext(c, next) {
  if (typeof next === "function") return next();
  if (typeof c?.next === "function") return c.next();
  return; // no-op if no next available
}

function guardMiddleware(c, next) {
  try {
    const method = String(c?.request?.method || "").toUpperCase();

    // Only police mutating verbs
    if (method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE") {
      // Get path defensively across envs
      const path =
        c?.request?.path ??
        c?.request?.url?.pathname ??
        c?.request?.url?.path ??
        c?.req?.path ?? // some loaders
        "";

      // Allow normal record CRUD under /api/collections/<name>/records...
      const allowRecords = /^\/api\/collections\/[^/]+\/records(?:\/|$)/i;

      // Block schema/admin/settings mutations (anything collections/* that isn't .../records)
      const blocked = [
        /^\/api\/collections(?:\/(?![^/]+\/records)(?:.*))?$/i,
        /^\/api\/collections\/(import|export|truncate)(?:\/|$)/i,
        /^\/api\/settings(?:\/|$)/i,
        /^\/api\/admins(?:\/|$)/i,
        /^\/api\/logs(?:\/|$)/i,
      ];

      // Explicit allow for record CRUD
      if (allowRecords.test(path)) {
        return _safeNext(c, next);
      }

      // Block schema/admin/settings writes
      for (const rx of blocked) {
        if (rx.test(path)) {
          const payload = {
            code: "read_only_admin",
            message: "Schema/config changes are disabled in this environment.",
          };

          // Try common response APIs without throwing
          try {
            if (typeof c?.json === "function") return c.json(payload, 403); // Hono style
          } catch (_) {}

          try {
            if (typeof c?.json === "function") return c.json(403, payload); // alt signature
          } catch (_) {}

          try {
            if (typeof c?.response?.json === "function") {
              c.response.status = 403;
              return c.response.json(payload);
            }
          } catch (_) {}

          try {
            if (c?.response) c.response.status = 403;
          } catch (_) {}

          // Last-resort return (don’t call next and don’t crash)
          return payload;
        }
      }
    }
  } catch (err) {
    try { console.log("[read-only-admin] middleware error:", err && (err.message || err)); } catch (_) {}
    // fall through
  }

  // Non-mutating or non-blocked → continue
  return _safeNext(c, next);
}

// Register in whichever environment is available
(function register() {
  let installed = false;

  if (typeof onBeforeServe === "function") {
    try {
      onBeforeServe(({ router }) => {
        router.use(guardMiddleware);
        try { console.log("[read-only-admin] enabled via onBeforeServe"); } catch (_) {}
      });
      installed = true;
    } catch (_) {}
  }

  if (typeof routerUse === "function") {
    try {
      routerUse(guardMiddleware);
      try { console.log("[read-only-admin] enabled via routerUse"); } catch (_) {}
      installed = true;
    } catch (_) {}
  }

  if (!installed) {
    try { console.log("[read-only-admin] not installed: no onBeforeServe/routerUse"); } catch (_) {}
  }
})();
