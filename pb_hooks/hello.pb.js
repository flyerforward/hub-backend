routerAdd("GET", "/healthz", (c) => c.json(200, { ok: 'hello world' }))

//routerAdd("GET", "/_", (c) => c.json(404, { message: 'Admin UI is disabled in production to prevent migration mismatches.' }))
routerAdd("GET", "/_/*", (c) => c.json(404, { message: 'Admin UI is disabled in production to prevent migration mismatches.' }))   