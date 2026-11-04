"""Tencent-side model worker. It never depends on the home Hermes node."""
import json
import logging
import os
import signal
import socket
import threading
import time
import uuid

from core import Problem, prompt_for, validate_result

log = logging.getLogger('ai-hub.worker')


def execute_one(database, proxy, owner):
    task = database.claim(owner)
    if not task:
        return False
    task_id, token = task['id'], task['lease_token']
    try:
        with database.connect() as db:
            model = database.model(db, task['model_id'])
        if not model or model['revision'] != task['model_revision']:
            database.finish(task_id, owner, token, error='configuration_changed', unstarted=True)
            return True
        proxy.sync(model)
    except Exception:
        database.finish(task_id, owner, token, error='model_unconfigured', unstarted=True)
        return True
    running = database.start(task_id, owner, token)
    if not running:
        try:
            database.finish(task_id, owner, token, error='configuration_changed', unstarted=True)
        except Problem:
            pass
        return True
    stopped = threading.Event()

    def heartbeat():
        while not stopped.wait(20):
            try:
                if not database.heartbeat(task_id, owner, token):
                    return
            except Exception:
                log.warning('heartbeat unavailable task=%s', task_id)

    thread = threading.Thread(target=heartbeat, daemon=True)
    thread.start()
    usage = None
    try:
        system, user = prompt_for(task['capability'], task['input'])
        raw, usage = proxy.invoke(model, system, user, task['max_output_tokens'])
        try:
            result = validate_result(task['capability'], json.loads(raw), task['input'])
        except (ValueError, TypeError):
            raise Problem('invalid_model_result', '模型结果格式无效', 502)
        database.finish(task_id, owner, token, result=result, usage=usage)
    except Problem as error:
        try:
            database.finish(task_id, owner, token, error=error.code, usage=usage)
        except Problem:
            pass
    except Exception:
        # Do not log raw upstream exceptions: they may embed provider keys and request bodies.
        log.error('task failed task=%s code=internal_error', task_id)
        try:
            database.finish(task_id, owner, token, error='internal_error', usage=usage)
        except Problem:
            pass
    finally:
        stopped.set()
        thread.join(timeout=1)
    return True


def main():
    from app import app
    database, proxy = app.extensions['database'], app.extensions['model_proxy']
    owner = f'{socket.gethostname()}:{os.getpid()}:{uuid.uuid4()}'
    stopping = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopping.set())
    logging.basicConfig(level=logging.INFO)
    while not stopping.is_set():
        try:
            if not execute_one(database, proxy, owner):
                stopping.wait(2)
        except Exception:
            log.error('worker unavailable; retrying without exposing request data')
            stopping.wait(5)


if __name__ == '__main__':
    main()
