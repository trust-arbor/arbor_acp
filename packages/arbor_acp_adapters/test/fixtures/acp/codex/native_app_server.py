#!/usr/bin/env python3
"""Credential-free native protocol peer; never runs tools or model inference."""
import json
import sys

def emit(value):
    print(json.dumps(value), flush=True)

pending = {}
server_id = 1000
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get('method')
    params = msg.get('params', {})
    request_id = msg.get('id')
    if method is None and request_id in pending:
        emit({'id': pending.pop(request_id), 'result': {'reply': msg}})
        continue
    if method == 'initialize':
        if params.get('clientInfo', {}).get('name') == 'reject':
            emit({'id': request_id, 'error': {'code': -32600, 'message': 'rejected', 'data': {'future': True}}})
        else:
            emit({'id': request_id, 'result': {'userAgent': 'test-peer'}})
    elif method == 'model/list':
        emit({'id': request_id, 'result': {'data': []}})
    elif method == 'test/fail':
        emit({'id': request_id, 'error': {'code': -32055, 'message': 'native error', 'data': [None, False], 'future': True}})
    elif method == 'test/events':
        emit({'method': 'future/event', 'params': {'data': [1, None]}, 'futureTopLevel': True})
        emit({'method': 'future/noParams', 'futureTopLevel': [True]})
        emit({'id': request_id, 'result': {}})
    elif method in ('test/ask', 'test/ask-no-params'):
        server_id += 1
        pending[server_id] = request_id
        request = {'id': server_id, 'method': params.get('method', 'item/tool/call')}
        if method == 'test/ask':
            request['params'] = {'arguments': {'unknown': True}, 'threadId': 'native-thread'}
        emit(request)
    elif method == 'test/never':
        pass
    elif method == 'thread/start':
        emit({'id': request_id, 'result': {'thread': {'id': 'native-thread', 'cwd': params['cwd']}, 'model': 'test-model'}})
    elif method == 'turn/start':
        emit({'id': request_id, 'result': {'turn': {'id': 'native-turn'}}})
        emit({'method': 'item/agentMessage/delta', 'params': {'threadId': params['threadId'], 'delta': 'structured'}})
        emit({'method': 'turn/completed', 'params': {'threadId': params['threadId'], 'turn': {'id': 'native-turn', 'status': 'completed'}}})
    elif method == 'initialized':
        pass
    elif request_id is not None:
        emit({'id': request_id, 'result': params})
