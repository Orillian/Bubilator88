import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import smoke_windows_mcp


class FailingApp:
    """Inject failures before any reset, input or disk mutation is attempted."""

    def __init__(self, fail_save=False, fail_restore=False, wrong_id=False, mounted=False):
        self.fail_save = fail_save
        self.fail_restore = fail_restore
        self.wrong_id = wrong_id
        self.mounted = mounted
        self.running = True
        self.calls = []

    def open(self, request, timeout):
        if not request.has_header('Authorization'):
            raise urllib.error.HTTPError(request.full_url, 401, 'Unauthorized', {}, None)
        message = json.loads(request.data)
        method = message['method']
        result = {}
        status = 200
        if method == 'notifications/initialized':
            status = 202
        elif method == 'initialize':
            result = {'serverInfo': {'name': 'test', 'version': '1'}}
        elif method == 'tools/list':
            result = {'tools': [{'name': name} for name in (
                'status', 'pause', 'resume', 'run_frames', 'key', 'screenshot',
                'mount_disk', 'eject_disk', 'save_state', 'load_state', 'reset',
                'type_text', 'read_text')]}
        elif method == 'tools/call':
            name = message['params']['name']
            self.calls.append(name)
            text = 'OK'
            error = False
            if name == 'status':
                text = json.dumps({'real_time': self.running, 't_states': 100,
                    'frames_run': 0, 'disks': [{'name': 'User disk' if self.mounted else None}, {'name': None}]})
            elif name in ('pause', 'resume'):
                self.running = name == 'resume'
            elif name == 'run_frames' or (name == 'save_state' and self.fail_save):
                text, error = 'Injected operation failure', True
            elif name == 'load_state' and self.fail_restore:
                text, error = 'Injected restore failure', True
            result = {'content': [{'type': 'text', 'text': text}], 'isError': error}
        reply = {'jsonrpc': '2.0', 'id': -1 if self.wrong_id else message.get('id'), 'result': result}
        response = io.BytesIO(json.dumps(reply).encode() if status == 200 else b'')
        response.status = status
        return response


class WindowsMcpSmokeTests(unittest.TestCase):
    def invoke(self, directory, app):
        settings = directory / 'settings.json'
        settings.write_text(json.dumps({'AutomationPort': 18801, 'AutomationToken': 'private-test-token'}))
        with patch.object(sys, 'argv', ['smoke_windows_mcp.py', '--settings', str(settings),
                                       '--output', str(directory / 'output')]), \
                patch('smoke_windows_mcp.urllib.request.urlopen', side_effect=app.open), \
                patch('smoke_windows_mcp.time.sleep'), contextlib.redirect_stdout(io.StringIO()):
            smoke_windows_mcp.main()

    def test_existing_output_is_rejected_before_contacting_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'output').mkdir()
            report = root / 'output' / 'report.json'
            report.write_text('previous result')
            app = FailingApp()
            with self.assertRaises(FileExistsError):
                self.invoke(root, app)
            self.assertEqual(app.calls, [])
            self.assertEqual(report.read_text(), 'previous result')

    def test_save_failure_restores_running_state_and_writes_failure_report(self):
        for running in (True, False):
            with self.subTest(running=running), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = FailingApp(fail_save=True)
                app.running = running
                with self.assertRaisesRegex(AssertionError, 'Injected operation failure'):
                    self.invoke(root, app)
                self.assertEqual(app.running, running)
                self.assertNotIn('load_state', app.calls)
                raw = (root / 'output' / 'report.json').read_text()
                self.assertEqual(json.loads(raw)['result'], 'failed')
                self.assertNotIn('private-test-token', raw)

    def test_existing_disk_is_rejected_before_machine_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = FailingApp(mounted=True)
            with self.assertRaisesRegex(AssertionError, 'both drives empty'):
                self.invoke(root, app)
            self.assertEqual(app.calls, ['status'])

    def test_restore_failure_does_not_skip_restoring_running_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = FailingApp(fail_restore=True)
            with self.assertRaisesRegex(AssertionError, 'Injected operation failure'):
                self.invoke(root, app)
            self.assertTrue(app.running)
            self.assertLess(app.calls.index('load_state'), app.calls.index('resume'))
            report = json.loads((root / 'output' / 'report.json').read_text())
            self.assertEqual(report['result'], 'failed')
            self.assertIn('Injected restore failure', str(report['cleanup_errors']))

    def test_mismatched_reply_id_fails_before_machine_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = FailingApp(wrong_id=True)
            with self.assertRaisesRegex(AssertionError, 'reply ID'):
                self.invoke(root, app)
            self.assertEqual(app.calls, [])
            self.assertEqual(json.loads((root / 'output' / 'report.json').read_text())['result'], 'failed')

    def test_optimized_python_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = root / 'settings.json'
            settings.write_text('{}')
            result = subprocess.run([sys.executable, '-O', smoke_windows_mcp.__file__,
                '--settings', str(settings), '--output', str(root / 'output')], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('without -O', result.stderr)
            self.assertFalse((root / 'output').exists())


if __name__ == '__main__':
    unittest.main()
