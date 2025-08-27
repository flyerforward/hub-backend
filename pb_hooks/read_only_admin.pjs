
routerUse((e) => {
  const ro = (env("PB_READONLY_ADMIN") || "").toLowerCase() === "true";
  if (!ro) return e.next();

  const m = e.request.method;
  if (m === "POST" || m === "PUT" || m === "PATCH" || m === "DELETE") {
    const p = e.request.path;

    // allow records CRUD under /api/collections/<name>/records...
    const isRecords = /^\/api\/collections\/[^/]+\/records(\/|$)/.test(p);
    if (isRecords) return e.next();

    const blocked = [
      /^\/api\/collections\/?$/,                 // create collection
      /^\/api\/collections\/[^/]+$/,             // update/delete collection
      /^\/api\/collections\/(import|export|truncate)(\/|$)/,
      /^\/api\/settings$/,                       // patch settings
      /^\/api\/admins(\/|$)/,                    // admin mgmt
      /^\/api\/logs(\/|$)/,                      // defensive
    ];

    if (blocked.some(re => re.test(p))) {
      e.response.status = 403;
      return e.response.json({
        code: "read_only_admin",
        message: "Schema/config changes are disabled in production."
      });
    }
  }

  return e.next();
});