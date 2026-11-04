#!/usr/bin/env python3
"""Outbound-only isolated Hermes worker; model credentials stay on the hub."""
import argparse
import json
import logging
import os
import random
import signal
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

LOG = logging.getLogger("ai-hub.oect")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # A worker credential may only reach the explicitly configured hub.
        return None


def settings(env=None):
    env = os.environ if env is None else env
    base = env.get("AI_HUB_URL", "https://ai.cliang.top").rstrip("/")
    parsed = urllib.parse.urlsplit(base)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.query or parsed.fragment
            or parsed.path or parsed.port not in (None, 443)):
        raise ValueError("AI_HUB_URL must be an HTTPS origin")
    key = env.get("AI_HUB_WORKER_KEY", "").strip()
    if not key or any(ord(c) < 33 or ord(c) > 126 for c in key):
        raise ValueError("worker credential is missing or invalid")
    version = env.get("HERMES_AGENT_VERSION", "unknown").strip()[:40]
    return base, key, version


class Node:
    def __init__(self, base, key, version, opener=None):
        self.base, self.key, self.version = base, key, version
        self.opener = opener or urllib.request.build_opener(
            NoRedirect(), urllib.request.ProxyHandler({}))

    def post(self, path, payload):
        request = urllib.request.Request(
            self.base + path, method="POST",
            data=json.dumps(payload, separators=(",", ":")).encode(),
            headers={"Authorization": "Bearer " + self.key,
                     "Content-Type": "application/json",
                     "User-Agent": "SideA-OECT-Node/1.0"})
        with self.opener.open(request, timeout=15) as response:
            raw = response.read(1048577)
        if len(raw) > 1048576:
            raise ValueError("hub response too large")
        result = json.loads(raw)
        if not isinstance(result, dict) or result.get("ok") is not True:
            raise ValueError("hub did not acknowledge request")
        return result

    def heartbeat(self, ready=False):
        # configured means the task-scoped central relay is supported; no
        # provider key or personal Hermes configuration exists on this node.
        payload = {"ready": ready, "model_configured": ready,
                   "agent_version": self.version,
                   "capabilities": ["hermes.analyze.v1"]}
        result = self.post("/v1/worker/status", payload)
        delay = result.get("retry_after_seconds", 30)
        if not isinstance(delay, (int, float)) or isinstance(delay, bool):
            delay = 30
        return max(10, min(float(delay), 120))

    def execute(self, task, runtime, stopped):
        task_id = str(uuid.UUID(task["id"]))
        token = task["lease_token"]
        ref = {"task_id": task_id, "lease_token": token}
        if (task.get("capability") != "hermes.analyze.v1"
                or task.get("model_base_url") != self.base + "/v1/worker/tasks/" + task_id
                or task.get("model_api_key") != token
                or not isinstance(task.get("input", {}).get("text"), str)):
            self.post("/v1/worker/complete", {**ref, "error": True})
            return
        # No request is sent to the model before the central lease CAS succeeds.
        self.post("/v1/worker/start", ref)
        proc = None
        result = None
        try:
            with tempfile.TemporaryDirectory(prefix="task-", dir="/var/lib/sidea-ai-worker/tasks") as scratch:
                # No previous app/device state, provider keys, gateway sessions,
                # installed plugins or personal memory are inherited by a task.
                env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8",
                       "HOME": scratch, "HERMES_HOME": scratch,
                       "PYTHONDONTWRITEBYTECODE": "1", "HERMES_DISABLE_TELEMETRY": "1",
                       "PYTHONPATH": runtime["source"],
                       "HERMES_RUNTIME_DIR": runtime["tools"]}
                config = {"model": {"streaming": False},
                          "memory": {"memory_enabled": False, "user_profile_enabled": False},
                          "auxiliary": {"title_generation": {"enabled": False, "model_upgrade_enabled": False}},
                          "display": {"streaming": False}, "plugins": {}, "mcp_servers": {}}
                Path(scratch, "config.yaml").write_text(json.dumps(config))
                payload = {"base_url": task["model_base_url"], "api_key": token,
                           "model": task.get("model", "hub-assigned"),
                           "text": task["input"]["text"],
                           "max_output_tokens": task["max_output_tokens"]}
                proc = subprocess.Popen(
                    [runtime["python"], "/opt/sidea-ai-worker/hermes_task.py"],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    cwd=scratch, env=env, start_new_session=True, text=True)
                deadline = time.monotonic() + 150
                initial = json.dumps(payload)
                while True:
                    try:
                        output, _ = proc.communicate(input=initial, timeout=20)
                        break
                    except subprocess.TimeoutExpired:
                        initial = None
                        heartbeat = self.post("/v1/worker/heartbeat", ref)
                        if stopped.is_set() or heartbeat.get("cancel_requested") or time.monotonic() > deadline:
                            raise TimeoutError("task stopped")
                if proc.returncode != 0 or len(output) > 1048576:
                    raise ValueError("isolated execution failed")
                reply = json.loads(output)
                if reply.get("tools") != 0 or reply.get("api_calls") != 1:
                    raise ValueError("unexpected execution surface")
                summary = reply.get("result", {}).get("summary")
                if not isinstance(summary, str) or not summary.strip() or len(summary) > 20000:
                    raise ValueError("invalid task result")
                result = {"summary": summary}
        except (KeyError, OSError, ValueError, urllib.error.URLError):
            LOG.warning("Isolated task did not complete; no automatic model retry")
        finally:
            if proc is not None and proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=10)
        # The hub owns authoritative usage and bills only its model relay.
        self.post("/v1/worker/complete", {**ref, **({"result": result} if result else {"error": True})})


def load_runtime():
    if os.environ.get("AI_HUB_EXECUTION_ENABLED") != "true":
        return None
    try:
        runtime = json.loads(Path("/etc/sidea-ai-worker/runtime.json").read_text())
        for key in ("python", "source", "tools"):
            path = Path(runtime[key]).resolve()
            if not path.is_relative_to("/var/lib/sidea-ai-worker/hermes") or not path.exists():
                return None
        if runtime.get("verified") is not True:
            return None
        return runtime
    except (OSError, KeyError, ValueError):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="send one status update")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        node = Node(*settings())
    except ValueError:
        LOG.error("Node configuration is missing or invalid; no task execution enabled")
        return 2
    stopped = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stopped.set())
    runtime = load_runtime()
    delay, failures, online, next_status = 30, 0, False, 0
    while not stopped.is_set():
        try:
            if time.monotonic() >= next_status:
                delay = node.heartbeat(ready=runtime is not None)
                next_status = time.monotonic() + delay
            failures = 0
            if not online:
                LOG.info("Hub connected; isolated node online, central model relay %s",
                         "ready" if runtime else "pending")
            online = True
            if args.once:
                return 0
            if runtime:
                task = node.post("/v1/worker/claim", {}).get("task")
                if task:
                    node.execute(task, runtime, stopped)
                    continue
                delay = 10
        except (OSError, ValueError, urllib.error.URLError):
            # Never log a response body, URL parameters, credentials or task text.
            failures += 1
            if online or failures == 1 or failures % 20 == 0:
                LOG.warning("Hub unavailable; retrying status only")
            online = False
            delay = min(60, 5 * 2 ** min(failures - 1, 4)) + random.uniform(0, 3)
            if args.once:
                return 1
        stopped.wait(delay)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
