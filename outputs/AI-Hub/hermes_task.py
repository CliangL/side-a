#!/usr/bin/env python3
"""One task, one fresh Hermes process, zero tools or personal state."""
import contextlib
import io
import json
import logging
import sys


def execute(payload):
    from run_agent import AIAgent
    agent = AIAgent(
        base_url=payload["base_url"], api_key=payload["api_key"],
        provider="custom", api_mode="chat_completions", model=payload["model"],
        enabled_toolsets=[], max_iterations=1, max_tokens=payload["max_output_tokens"],
        skip_context_files=True, skip_memory=True, skip_background_review=True,
        load_soul_identity=False, save_trajectories=False, quiet_mode=True,
        verbose_logging=False, platform="batch", run_budget_seconds=120,
        request_overrides={"stream": False})
    try:
        if agent.tools:
            raise ValueError("tool isolation failed")
        result = agent.run_conversation(payload["text"])
        if result.get("failed") or result.get("error"):
            raise ValueError("model turn failed")
        answer = json.loads(result["final_response"])
        if not isinstance(answer, dict) or not isinstance(answer.get("summary"), str):
            raise ValueError("invalid structured result")
        return {"result": {"summary": answer["summary"]}, "tools": len(agent.tools),
                "api_calls": result.get("api_calls", 0)}
    finally:
        agent.close()


def main():
    logging.disable(logging.CRITICAL)
    raw = sys.stdin.read(65537)
    if len(raw) > 65536:
        return 2
    try:
        payload = json.loads(raw)
        # Hermes diagnostics may contain model text. Keep stdout machine-readable
        # and never persist captured diagnostics in the node service journal.
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            answer = execute(payload)
        sys.stdout.write(json.dumps(answer, ensure_ascii=False))
        return 0
    except Exception:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
