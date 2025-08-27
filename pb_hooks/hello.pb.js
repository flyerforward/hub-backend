routerAdd("GET", "/healthz", (c) => c.json(200, { ok: 'hello world' }))



/// <reference path="../pb_data/types.d.ts" />
(function(){
  function read(p){ try { return String(toString($os.readFile(p))).trim(); } catch(_) { return ""; } }
  var img = read("/app/pb_hooks/.schema_hash");
  var db  = read("/pb_data/.schema_hash");
  if (!img || !db || img === db) { return; } // ok

  function deny(c){
    var body = {
      code: "schema_mismatch",
      message: "This database schema differs from the running image. Deploy a build whose migrations match this schema to re-enable Admin UI.",
      expected_schema: db,
      running_schema: img
    };
    try { return c.json(body, 409); } catch(_) {}
    try { return c.json(409, body); } catch(_) {}
    return;
  }

  try { routerAdd("GET",  "/_/*", deny); } catch(_){}
  try { routerAdd("HEAD", "/_/*", deny); } catch(_){}
  ["GET","HEAD","POST","PUT","PATCH","DELETE","OPTIONS"].forEach(m=>{
    try { routerAdd(m, "/api/admins/*", deny); } catch(_){}
  });
})();
