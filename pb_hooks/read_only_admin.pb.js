onBeforeServe(({ router }) => {
  const allowRecords = /^\/api\/collections\/[^/]+\/records(?:\/|$)/i;
  const blocked = [
    /^\/api\/collections(?:\/(?![^/]+\/records)(?:.*))?$/i,
    /^\/api\/collections\/(import|export|truncate)(?:\/|$)/i,
    /^\/api\/settings(?:\/|$)/i,
    /^\/api\/admins(?:\/|$)/i,
    /^\/api\/logs(?:\/|$)/i,
  ];

  router.use((c, next) => {
    try {
      const method = String(c?.request?.method || "").toUpperCase();
      if (method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE") {
        const path =
          c?.request?.path ??
          c?.request?.url?.pathname ??
          c?.request?.url?.path ??
          "";

        if (allowRecords.test(path)) return next();
        for (const rx of blocked) {
          if (rx.test(path)) {
            return c.json(403, {
              code: "read_only_admin",
              message: "Schema/config changes are disabled in this environment.",
            });
          }
        }
      }
    } catch (e) {
      try { console.log("[read-only-admin] middleware error:", e && (e.message || e)); } catch (_) {}
    }
    return next();
  });

  try { console.log("[read-only-admin] enabled (pb_hooks)"); } catch (_) {}
});
