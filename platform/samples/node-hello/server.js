// Trivial zero-dependency Node app. Binds 0.0.0.0:$PORT — the platform injects
// PORT, and the generated Dockerfile is expected to honor it.
const http = require("http");
const port = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(`hello from node-hello — ${req.method} ${req.url}\n`);
});

server.listen(port, "0.0.0.0", () => {
  console.log(`node-hello listening on 0.0.0.0:${port}`);
});
