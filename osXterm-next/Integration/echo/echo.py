import asyncio


async def echo(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


async def main():
    server = await asyncio.start_server(echo, "0.0.0.0", 9000)
    async with server:
        await server.serve_forever()


asyncio.run(main())
