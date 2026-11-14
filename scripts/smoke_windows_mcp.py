#!/usr/bin/env python3
"""Exercise an already-running Windows app over its authenticated MCP endpoint.

Use an idle BASIC window with both drives empty and no other MCP clients.
The script restores the machine and running state, but the temporary disk is
added to the app's recent files. It does not launch the app or enable MCP.
Use a new output directory for each run; it retains snapshots and diagnostics.
"""
import argparse
import base64
import json
from pathlib import Path
import struct
import sys
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.flags.optimize:
        parser.error('Run without -O/-OO; validation assertions must be enabled.')
    settings = json.loads(args.settings.read_text(encoding='utf-8-sig'))
    output = args.output.resolve()
    output.mkdir(parents=True)
    endpoint = f"http://127.0.0.1:{settings['AutomationPort']}/mcp"
    records = []
    sequence = 0

    def rpc(method, params=None, notification=False, authenticated=True):
        nonlocal sequence
        sequence += 1
        message = {'jsonrpc': '2.0', 'method': method}
        if not notification:
            message['id'] = sequence
        if params is not None:
            message['params'] = params
        headers = {'Content-Type': 'application/json'}
        if authenticated:
            headers['Authorization'] = 'Bearer ' + settings['AutomationToken']
        request = urllib.request.Request(endpoint, json.dumps(message).encode(), headers)
        with urllib.request.urlopen(request, timeout=60) as response:
            status = response.status
            payload = response.read()
        records.append({'method': method, 'params': params, 'http_status': status})
        assert status == (202 if notification else 200), f'Unexpected HTTP status: {status}'
        result = json.loads(payload) if payload else None
        if notification:
            assert result is None, 'Notification unexpectedly returned a reply'
        else:
            assert isinstance(result, dict), 'Missing JSON-RPC reply'
            assert result.get('jsonrpc') == '2.0', 'Invalid JSON-RPC version'
            assert result.get('id') == sequence, 'Mismatched JSON-RPC reply ID'
            assert 'error' not in result, result
        return result['result'] if result else None

    def tool(name, **arguments):
        result = rpc('tools/call', {'name': name, 'arguments': arguments})
        assert not result.get('isError', False), result
        return result

    def status():
        return json.loads(tool('status')['content'][0]['text'])

    original = None
    initialized = None
    tools = []
    restore = output / 'original.b88s'
    mutated = False
    saved = False
    failure = None
    cleanup_errors = []
    try:
        try:
            rpc('ping', authenticated=False)
            raise AssertionError('Unauthenticated connection was accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 401, error.code
            records.append({'check': 'unauthenticated_request', 'http_status': error.code})

        initialized = rpc('initialize', {'protocolVersion': '2025-03-26',
            'capabilities': {}, 'clientInfo': {'name': 'windows-app-smoke', 'version': '1'}})
        rpc('notifications/initialized', notification=True)
        rpc('ping')
        tools = rpc('tools/list')['tools']
        names = {entry['name'] for entry in tools}
        assert {'status', 'pause', 'resume', 'run_frames', 'key', 'screenshot',
                'mount_disk', 'eject_disk', 'save_state', 'load_state', 'reset',
                'type_text', 'read_text'} <= names
        original = status()
        assert all(disk['name'] is None for disk in original['disks']), \
            'Use a BASIC window with both drives empty'
        mutated = True
        tool('pause')
        paused = status()
        assert not paused['real_time']
        time.sleep(0.2)
        assert status()['t_states'] == paused['t_states']
        tool('save_state', path=str(restore))
        saved = True
        tool('run_frames', frames=3)
        advanced = status()
        assert advanced['frames_run'] == paused['frames_run'] + 3
        assert advanced['t_states'] > paused['t_states']
        assert not advanced['real_time']
        tool('resume')
        running = status()
        assert running['real_time']
        time.sleep(0.2)
        assert status()['t_states'] > running['t_states']
        tool('pause')
        tool('key', key='shift', action='down')
        tool('key', key='shift', action='up')
        screenshot = tool('screenshot')
        png = base64.b64decode(next(c['data'] for c in screenshot['content'] if c['type'] == 'image'))
        assert png[:8] == b'\x89PNG\r\n\x1a\n'
        assert struct.unpack_from('>II', png, 16) == (640, 400)
        (output / 'screen.png').write_bytes(png)
        tool('reset', warm=True)
        reset = status()
        assert not reset['real_time']
        assert (reset['mode'], reset['clock']) == (original['mode'], original['clock'])
        tool('run_frames', frames=120)
        text = tool('read_text')['content'][0]['text']
        if 'How many files' in text:
            tool('type_text', text='0\n', max_frames=600)
            tool('run_frames', frames=60)
        tool('type_text', text='PRINT "MCP SMOKE OK"\n', max_frames=600)
        tool('run_frames', frames=30)
        text = tool('read_text')['content'][0]['text']
        assert text.count('MCP SMOKE OK') >= 2, text
        (output / 'screen-text.txt').write_text(text, encoding='utf-8')
        typed = tool('screenshot')
        (output / 'basic.png').write_bytes(base64.b64decode(
            next(c['data'] for c in typed['content'] if c['type'] == 'image')))
        tool('save_state', path=str(output / 'basic.b88s'))

        images = bytearray()
        for name in ('Image A', 'Image B'):
            image = bytearray(0x2b0)
            image[:len(name)] = name.encode('ascii')
            struct.pack_into('<I', image, 0x1c, len(image))
            images.extend(image)
        disk_path = output / 'game.release.v1.2.d88'
        disk_path.write_bytes(images)
        tool('mount_disk', drive=2, path=str(disk_path), image=0, write_protected=True)
        tool('run_frames', frames=10)
        disk = status()['disks'][1]
        assert disk['name'] == 'Image A' and disk['write_protected']
        snapshot = output / 'protected.b88s'
        tool('save_state', path=str(snapshot))
        blob = snapshot.read_bytes()
        assert len(blob) >= 64 and blob[:4] == b'BU88', 'Invalid save-state header'
        section_count = struct.unpack_from('<I', blob, 0x3c)[0]
        table_end = 64 + section_count * 12
        assert table_end <= len(blob), 'Truncated save-state section table'
        sections = {}
        for index in range(section_count):
            tag, offset, size = struct.unpack_from('<4sII', blob, 64 + index * 12)
            assert offset >= table_end and offset + size <= len(blob), 'Invalid section bounds'
            sections[tag] = blob[offset:offset + size]
        assert isinstance(json.loads(sections[b'AMTA']), dict), 'Missing app metadata'
        assert sections[b'THMB'][:8] == b'\x89PNG\r\n\x1a\n', 'Missing PNG thumbnail'
        assert not snapshot.with_suffix('.meta.json').exists()
        assert not snapshot.with_suffix('.thumb.png').exists()
        tool('eject_disk', drive=2)
        assert status()['disks'][1]['name'] is None
        tool('load_state', path=str(snapshot))
        disk = status()['disks'][1]
        assert disk['name'] == 'Image A' and disk['write_protected']
    except BaseException as error:
        failure = error
    finally:
        if mutated:
            try:
                if saved:
                    tool('load_state', path=str(restore))
            except Exception as error:
                cleanup_errors.append(f'Machine restoration failed: {error}')
            try:
                tool('resume' if original['real_time'] else 'pause')
            except Exception as error:
                cleanup_errors.append(f'Running-state restoration failed: {error}')

    final_status = None
    if mutated:
        try:
            final_status = status()
        except Exception as error:
            cleanup_errors.append(f'Final status failed: {error}')
    report = {'result': 'passed' if failure is None and not cleanup_errors else 'failed',
              'server': initialized.get('serverInfo') if initialized else None,
              'tool_count': len(tools), 'initial_status': original,
              'final_status': final_status, 'requests': records,
              'error': f'{type(failure).__name__}: {failure}' if failure else None,
              'cleanup_errors': cleanup_errors}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    if failure is not None:
        raise failure
    if cleanup_errors:
        raise RuntimeError('; '.join(cleanup_errors))
    print(json.dumps({'result': report['result'], 'tool_count': len(tools),
                      'requests': len(records), 'report': str(output / 'report.json')}))


if __name__ == '__main__':
    main()
