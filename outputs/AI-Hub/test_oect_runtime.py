"""Run on the OECT node as its isolated worker user; no external/model calls."""
import http.server
import json
import os
import subprocess
import tempfile
import threading
from pathlib import Path


def main():
    runtime = json.loads(Path('/etc/sidea-ai-worker/runtime.json').read_text())
    calls = []

    class Model(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            # Hermes probes localhost for Ollama metadata. That is not a model
            # call and is not available on the production HTTPS relay either.
            if self.path != '/v1/chat/completions':
                self.send_error(404)
                return
            calls.append(body)
            reply = {'id': 'isolated-test', 'object': 'chat.completion', 'created': 1,
                     'model': 'assigned-model', 'choices': [{'index': 0, 'finish_reason': 'stop',
                         'message': {'role': 'assistant', 'content': '{"summary":"隔离执行验证通过"}'}}],
                     'usage': {'prompt_tokens': 10, 'completion_tokens': 8, 'total_tokens': 18}}
            data = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(dir='/var/lib/sidea-ai-worker/tasks', prefix='selftest-') as scratch:
            env = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'HOME': scratch,
                   'HERMES_HOME': scratch, 'HERMES_RUNTIME_DIR': runtime['tools'],
                   'PYTHONPATH': runtime['source'], 'PYTHONDONTWRITEBYTECODE': '1'}
            Path(scratch, 'config.yaml').write_text(json.dumps({
                'model': {'streaming': False}, 'memory': {'memory_enabled': False,
                'user_profile_enabled': False}, 'auxiliary': {'title_generation': {
                    'enabled': False, 'model_upgrade_enabled': False}}, 'plugins': {}, 'mcp_servers': {}}))
            payload = {'base_url': 'http://127.0.0.1:' + str(server.server_port) + '/v1',
                       'api_key': 'integration-test-not-a-key', 'model': 'assigned-model',
                       'text': 'This is synthetic integration-test data.', 'max_output_tokens': 200}
            result = subprocess.run([runtime['python'], '/opt/sidea-ai-worker/hermes_task.py'],
                                    input=json.dumps(payload), capture_output=True,
                                    cwd=scratch, env=env, text=True, timeout=150)
            assert result.returncode == 0, 'Isolated Hermes process failed'
            answer = json.loads(result.stdout)
            assert answer['result']['summary'] == '隔离执行验证通过', 'Unexpected model result'
            assert answer['tools'] == 0 and answer['api_calls'] == 1, 'Wrong agent limits'
            assert len(calls) == 1, 'Expected exactly one model call; got ' + str(len(calls))
            assert not calls[0].get('tools') and not calls[0].get('functions'), 'Tools leaked'
            assert calls[0].get('stream') is False, 'Streaming must be disabled'
            for path in ('/root/.hermes/config.yaml', '/root/.hermes/auth.json'):
                assert not os.access(path, os.R_OK), 'Personal Hermes state readable'
            print(json.dumps({'ok': True, 'model_requests': len(calls), 'tools': 0,
                              'stream': False, 'personal_state_readable': False}))
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
