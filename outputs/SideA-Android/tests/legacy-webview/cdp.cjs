const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.events = [];
    ws.addEventListener("message", (e) => {
      const v = JSON.parse(e.data);
      if (v.id) {
        const p = this.pending.get(v.id);
        if (!p) return;
        this.pending.delete(v.id);
        clearTimeout(p.timer);
        v.error ? p.reject(v.error) : p.resolve(v.result);
      } else this.events.push(v);
    });
  }
  call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.id;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error("CDP timed out: " + method)); }, 15000);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async eval(expression) {
    const r = await this.call("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (r.exceptionDetails) throw Error(JSON.stringify(r.exceptionDetails));
    return r.result.value;
  }
}
async function connect(port = 9227) {
  const version = await (
    await fetch("http://127.0.0.1:" + port + "/json/version")
  ).json();
  const page = await (
    await fetch("http://127.0.0.1:" + port + "/json/new")
  ).json();
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });
  const c = new CDP(ws);
  await c.call("Runtime.enable");
  await c.call("Page.enable");
  await c.call("Emulation.setDeviceMetricsOverride", {
    width: 1024,
    height: 600,
    deviceScaleFactor: 1,
    mobile: false,
  });
  return {
    c,
    version,
    close: async () => {
      ws.close();
      await fetch("http://127.0.0.1:" + port + "/json/close/" + page.id);
    },
  };
}
module.exports = { connect, sleep };
