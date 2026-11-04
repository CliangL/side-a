const http = require("node:http"),
  fs = require("node:fs"),
  path = require("node:path");
const roots = {
  old: path.resolve("work/old-webview/old"),
  new: path.resolve("outputs/SideA-Android/app/src/main/assets"),
  phone: path.resolve("outputs/SideA-Android/app/src/main/assets"),
};
http
  .createServer((req, res) => {
    const parts = new URL(req.url, "http://localhost").pathname.split("/");
    const root = roots[parts[1]];
    if (!root) {
      res.writeHead(404);
      return res.end();
    }
    let file = parts.slice(2).join("/") || "index.html";
    if (file.includes("..")) {
      res.writeHead(403);
      return res.end();
    }
    try {
      let data = fs.readFileSync(
        file === "__bridge.js"
          ? path.join(__dirname, "bridge.js")
          : path.join(root, file),
      );
      if (file === "index.html")
        data = Buffer.from(
          data
            .toString()
            .replace(
              '<script defer src="core.js">',
              '<script src="__bridge.js"></script>\n    <script defer src="core.js">',
            ),
        );
      res.writeHead(200, {
        "Content-Type":
          {
            ".html": "text/html",
            ".js": "application/javascript",
            ".css": "text/css",
            ".jpg": "image/jpeg",
          }[path.extname(file)] || "application/octet-stream",
      });
      res.end(data);
    } catch {
      res.writeHead(404);
      res.end();
    }
  })
  .listen(18771, "127.0.0.1");
