#!/usr/bin/env python3
import argparse
import asyncio
import base64
import hashlib
import pathlib
import ssl
import subprocess
import tempfile

CASE_TIMEOUT_SECONDS = 15
MAX_OUTPUT_BYTES = 1 << 20


async def websocket_server(reader, writer, valid_upgrade=True):
    try:
        request = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 5)
        key_line = next(line for line in request.split(b"\r\n") if line.lower().startswith(b"sec-websocket-key:"))
        key = key_line.split(b":", 1)[1].strip()
        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        if valid_upgrade:
            writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            writer.write(b"\x81\x06secure")
        else:
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        await writer.drain()
        await asyncio.sleep(0.1)
    except (asyncio.IncompleteReadError, ConnectionError, StopAsyncIteration):
        pass
    finally:
        writer.close()
        await writer.wait_closed()


async def run_case(name, fixture, collection, pki, certificate, key, ca_file, expected_error, expect_message, valid_upgrade=True):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(pki / certificate, pki / key)
    server = await asyncio.start_server(
        lambda reader, writer: websocket_server(reader, writer, valid_upgrade),
        "127.0.0.1",
        0,
        ssl=context,
    )
    port = server.sockets[0].getsockname()[1]
    command = [
        "odin",
        "run",
        str(fixture),
        collection,
        "--",
        f"wss://localhost:{port}/secure?case={name}",
        str(pki / ca_file) if ca_file else "",
        str(expected_error),
        "1" if expect_message else "0",
    ]
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        output, _ = await asyncio.wait_for(process.communicate(), CASE_TIMEOUT_SECONDS)
        if len(output) > MAX_OUTPUT_BYTES:
            raise RuntimeError(f"{name}: output exceeded limit")
        if process.returncode != 0:
            raise RuntimeError(f"{name}: fixture failed\n{output.decode(errors='replace')}")
    finally:
        server.close()
        await server.wait_closed()
    print(f"wss-loopback: {name} PASS")


async def run_matrix(fixture, collection, pki):
    await run_case("valid", fixture, collection, pki, "localhost.pem", "localhost-key.pem", "root-ca.pem", 0, True)
    await run_case("untrusted", fixture, collection, pki, "localhost.pem", "localhost-key.pem", "", 4, False)
    await run_case("wrong-host", fixture, collection, pki, "wrong.pem", "wrong-key.pem", "root-ca.pem", 4, False)
    await run_case("bad-upgrade", fixture, collection, pki, "localhost.pem", "localhost-key.pem", "root-ca.pem", 5, False, False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    parser.add_argument("--collection", required=True)
    args = parser.parse_args()
    pki = pathlib.Path(__file__).resolve().parents[1] / "testdata" / "wss"
    with tempfile.TemporaryDirectory(prefix="ingot-wss-"):
        asyncio.run(run_matrix(args.fixture, args.collection, pki))


if __name__ == "__main__":
    main()
