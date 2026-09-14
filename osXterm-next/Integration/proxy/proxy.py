import asyncio
import base64
import binascii
import hmac
import ipaddress
import os
import sys


async def relay(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


async def connect(host, port):
    return await asyncio.open_connection(host, port)


def expected_credentials():
    username = os.environ.get("PROXY_USERNAME")
    password = os.environ.get("PROXY_PASSWORD")
    if not username and not password:
        return None
    if not username or password is None:
        raise RuntimeError("Both PROXY_USERNAME and PROXY_PASSWORD are required")
    return username.encode("utf-8"), password.encode("utf-8")


def http_credentials_match(headers, credentials):
    if credentials is None:
        return True
    value = headers.get("proxy-authorization", "")
    if not value.lower().startswith("basic "):
        return False
    try:
        encoded = value.split(" ", 1)[1]
        received = base64.b64decode(encoded, validate=True)
    except (IndexError, ValueError, binascii.Error):
        return False
    expected = credentials[0] + b":" + credentials[1]
    return hmac.compare_digest(received, expected)


async def http_connect(client_reader, client_writer, credentials):
    line = await client_reader.readline()
    if not line.startswith(b"CONNECT "):
        client_writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
        await client_writer.drain()
        client_writer.close()
        return
    authority = line.split()[1].decode("ascii")
    if authority.startswith("["):
        host, remainder = authority[1:].split("]", 1)
        port = int(remainder[1:])
    else:
        host, port_text = authority.rsplit(":", 1)
        port = int(port_text)
    headers = {}
    while True:
        header = await client_reader.readline()
        if header in (b"\r\n", b""):
            break
        try:
            key, value = header.decode("ascii").split(":", 1)
        except ValueError:
            client_writer.close()
            return
        headers[key.strip().lower()] = value.strip()
    if not http_credentials_match(headers, credentials):
        client_writer.write(
            b"HTTP/1.1 407 Proxy Authentication Required\r\n"
            b"Proxy-Authenticate: Basic realm=\"osXterm integration\"\r\n\r\n"
        )
        await client_writer.drain()
        client_writer.close()
        return
    try:
        target_reader, target_writer = await connect(host, port)
    except OSError:
        client_writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        await client_writer.drain()
        client_writer.close()
        return
    client_writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    await client_writer.drain()
    await asyncio.gather(relay(client_reader, target_writer), relay(target_reader, client_writer))


async def socks5(client_reader, client_writer, credentials):
    version, method_count = await client_reader.readexactly(2)
    if version != 5:
        client_writer.close()
        return
    methods = await client_reader.readexactly(method_count)
    method = 2 if credentials is not None and 2 in methods else (0 if credentials is None and 0 in methods else 255)
    client_writer.write(bytes([5, method]))
    await client_writer.drain()
    if method == 255:
        client_writer.close()
        return
    if method == 2:
        try:
            version = (await client_reader.readexactly(1))[0]
            username_length = (await client_reader.readexactly(1))[0]
            username = await client_reader.readexactly(username_length)
            password_length = (await client_reader.readexactly(1))[0]
            password = await client_reader.readexactly(password_length)
        except asyncio.IncompleteReadError:
            client_writer.close()
            return
        authenticated = version == 1 and hmac.compare_digest(username, credentials[0]) and hmac.compare_digest(password, credentials[1])
        client_writer.write(bytes([1, 0 if authenticated else 1]))
        await client_writer.drain()
        if not authenticated:
            client_writer.close()
            return
    version, command, _, address_type = await client_reader.readexactly(4)
    if version != 5 or command != 1:
        client_writer.close()
        return
    if address_type == 1:
        host = str(ipaddress.ip_address(await client_reader.readexactly(4)))
    elif address_type == 4:
        host = str(ipaddress.ip_address(await client_reader.readexactly(16)))
    elif address_type == 3:
        length = (await client_reader.readexactly(1))[0]
        host = (await client_reader.readexactly(length)).decode("idna")
    else:
        client_writer.close()
        return
    port = int.from_bytes(await client_reader.readexactly(2), "big")
    try:
        target_reader, target_writer = await connect(host, port)
    except OSError:
        client_writer.write(bytes([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]))
        await client_writer.drain()
        client_writer.close()
        return
    client_writer.write(bytes([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
    await client_writer.drain()
    await asyncio.gather(relay(client_reader, target_writer), relay(target_reader, client_writer))


async def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "http"
    port = 3128 if mode == "http" else 1080
    credentials = expected_credentials()
    if mode == "http":
        handler = lambda reader, writer: http_connect(reader, writer, credentials)
    else:
        handler = lambda reader, writer: socks5(reader, writer, credentials)
    server = await asyncio.start_server(handler, "0.0.0.0", port)
    async with server:
        await server.serve_forever()


asyncio.run(main())
