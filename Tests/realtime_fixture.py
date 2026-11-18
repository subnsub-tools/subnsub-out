"""Local protocol fixture, not a speech-recognition or live OpenAI test."""
import asyncio
import base64
import json
import sys
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed


async def handle(socket):
    try:
        assert socket.request.headers["Authorization"] == "Bearer fixture-key"
        config = json.loads(await socket.recv())
        assert config["type"] == "session.update"
        assert config["session"]["audio"]["input"]["turn_detection"] is None
        if socket.request.path == "/reject":
            await socket.send(json.dumps({"type": "error", "error": {"code": "invalid_api_key", "message": "secret-canary"}}))
            return
        await socket.send(json.dumps({"type": "session.created"}))
        await socket.send(json.dumps({"type": "session.updated"}))
        total = 0
        async for raw in socket:
            event = json.loads(raw)
            if event["type"] == "input_audio_buffer.append":
                data = base64.b64decode(event["audio"])
                assert all(value == 1 for value in data)
                total += len(data)
                # "Wednesday" in Chinese, a partial transcript.
                await socket.send(json.dumps({"type": "conversation.item.input_audio_transcription.delta", "item_id": "turn", "delta": "\u5468\u4e09"}))
                if socket.request.path == "/drop":
                    await socket.close(code=1011, reason="fixture disconnect")
                    return
            elif event["type"] == "input_audio_buffer.commit":
                assert total == 9600, total
                if socket.request.path == "/timeout":
                    await socket.wait_closed()
                    return
                # "Meeting Thursday at 3 p.m." in Chinese, the final transcript.
                final = {"type": "conversation.item.input_audio_transcription.completed", "item_id": "turn", "transcript": "\u5468\u56db\u4e0b\u5348\u4e09\u70b9\u5f00\u4f1a\u3002"}
                commit = {"type": "input_audio_buffer.committed", "item_id": "turn", "previous_item_id": None}
                for value in ([final, commit] if socket.request.path == "/reordered" else [commit, final]):
                    await socket.send(json.dumps(value))
                return
    except ConnectionClosed:
        pass


async def main():
    async with serve(handle, "127.0.0.1", int(sys.argv[1])):
        print("Protocol fixture ready", flush=True)
        await asyncio.Future()


asyncio.run(main())
