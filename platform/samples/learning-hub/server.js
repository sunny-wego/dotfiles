// AI Literacy Learning Hub — MINIMAL representative.
// Real needs: frontend+API, DB, SSO, custom domain.
// v1 support exercised: a frontend page AND a JSON API in one container, the
// per-tenant DB (DATABASE_URL), and SSO via the platform's company-Google login
// (whole-app). Custom domain is target-arch; v1 serves on a platform subdomain.
const http = require("http"), net = require("net");
const PORT = process.env.PORT || 3000;

function dbCheck(cb) {
  const u = process.env.DATABASE_URL || "";
  if (!u.includes("@")) return cb(false, "no DATABASE_URL");
  const [host, port] = u.split("@")[1].split("/")[0].split(":");
  const s = net.connect({ host, port: +(port || 5432), timeout: 3000 }, () => { s.end(); cb(true, `${host}:${port||5432}`); });
  s.on("error", e => cb(false, e.message));
  s.on("timeout", () => { s.destroy(); cb(false, "timeout"); });
}

http.createServer((req, res) => {
  if (req.url.startsWith("/api/modules")) {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ modules: ["Prompting 101", "RAG basics", "Evals"] }));
  }
  dbCheck((ok, detail) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<h1>AI Literacy Learning Hub</h1><p>minimal frontend + API + DB.</p>
<ul><li>DB reachable: ${ok} (${detail})</li>
<li>API: <a href="/api/modules">/api/modules</a></li>
<li>SSO: company Google via platform (whole-app)</li></ul>`);
  });
}).listen(PORT, () => console.log("learning-hub on " + PORT));
