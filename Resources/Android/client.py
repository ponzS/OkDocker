"""OkDocker's project-private ADB client transport. No host shell or USB keys."""
import asyncio
import json
import os
from pathlib import Path

CONFIG = json.loads(Path(os.environ.get('OKDOCKER_BRIDGE_CONFIG', '/run/bridge.json')).read_text())

async def relay(reader, writer):
    try:
        while chunk := await reader.read(65536):
            writer.write(chunk)
            await writer.drain()
    finally:
        try:
            writer.write_eof()
        except (OSError, NotImplementedError):
            pass

async def accept(reader, writer):
    remote_writer = None
    try:
        connect = (asyncio.open_unix_connection(CONFIG['socket']) if 'socket' in CONFIG
                   else asyncio.open_connection(CONFIG['host'], CONFIG['port']))
        remote_reader, remote_writer = await asyncio.wait_for(connect, timeout=10)
        remote_writer.write((CONFIG['token'] + '\n').encode())
        await remote_writer.drain()
        tasks = [asyncio.create_task(relay(reader, remote_writer)),
                 asyncio.create_task(relay(remote_reader, writer))]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        # Give the response stream a bounded chance to drain on half-close.
        for task in pending:
            try:
                await asyncio.wait_for(task, 3)
            except (TimeoutError, OSError, ConnectionError):
                task.cancel()
        for task in done:
            task.result()
    except (OSError, TimeoutError, ConnectionError):
        pass
    finally:
        writer.close()
        if remote_writer is not None:
            remote_writer.close()

async def main():
    if 'listenSocket' in CONFIG:
        server = await asyncio.start_unix_server(accept, CONFIG['listenSocket'], limit=65536)
    else:
        server = await asyncio.start_server(accept, '0.0.0.0', 5037, limit=65536)
    async with server:
        await server.serve_forever()

asyncio.run(main())
