"use strict";
// Optional static guard: npm install --prefix work/old-webview/tools acorn@8.15.0
// NODE_PATH="$PWD/work/old-webview/tools/node_modules" node <this file>
const fs = require("node:fs");
const path = require("node:path");
const acorn = require("acorn");
const assets = path.resolve(__dirname, "../../app/src/main/assets");
const targets = fs
  .readdirSync(assets)
  .filter((file) => file.endsWith(".js"))
  .map((file) => ({
    file: path.join(assets, file),
    ecmaVersion: file === "bootstrap.js" ? 5 : 2017,
  }));
targets.push({ file: path.join(__dirname, "bridge.js"), ecmaVersion: 5 });
for (const { file, ecmaVersion } of targets) {
  try {
    acorn.parse(fs.readFileSync(file, "utf8"), {
      ecmaVersion,
      sourceType: "script",
    });
  } catch (error) {
    throw new Error(
      path.basename(file) +
        " does not parse as " +
        ecmaVersion +
        ": " +
        error.message,
    );
  }
}
console.log(
  "Parsed " +
    targets.length +
    " scripts: bootstrap and fixture ES5, app ES2017.",
);
