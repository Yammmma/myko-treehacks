import asyncio
import json

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from agent import Agent
from tracker import Segmenter

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

segmenter = Segmenter()
agent = Agent(segmenter, debug=True)
print("🚀 Server ready on :8000  (set OPENAI_API_KEY before sending /query requests)")


class ChatRequest(BaseModel):
    prompt: str
    frame: str | None = None


@app.post("/query")
async def query_endpoint(request: ChatRequest):
    response = await agent.query(request.prompt, request.frame)
    return {"response": response}


def _extract_frame(message: dict) -> str | None:
    if "text" in message:
        try:
            data = json.loads(message["text"])
            return data.get("frame")
        except Exception:
            return message["text"]
    if "bytes" in message:
        try:
            data = json.loads(message["bytes"])
            return data.get("frame")
        except Exception:
            return message["bytes"].decode("utf-8")
    return None


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    print("✅ WS Connected")

    latest_frame: dict = {"data": None, "event": asyncio.Event()}

    async def receiver():
        try:
            while True:
                message = await websocket.receive()
                if message["type"] == "websocket.disconnect":
                    raise WebSocketDisconnect()
                frame = _extract_frame(message)
                if frame:
                    latest_frame["data"] = frame
                    latest_frame["event"].set()
        except (WebSocketDisconnect, Exception):
            latest_frame["event"].set()
            raise

    async def processor():
        try:
            while True:
                await latest_frame["event"].wait()
                latest_frame["event"].clear()

                frame = latest_frame["data"]
                if frame is None:
                    continue

                try:
                    edited_frame = await asyncio.to_thread(segmenter.render_frame, frame)
                except Exception as render_err:
                    print(f"⚠️ Frame render error: {render_err}")
                    edited_frame = frame.split(",", 1)[-1] if "," in frame else frame

                await websocket.send_text(edited_frame)
        except Exception:
            raise

    try:
        await asyncio.gather(receiver(), processor())
    except WebSocketDisconnect:
        print("❌ WS Disconnected")
    except Exception as err:
        print(f"⚠️ WS Error: {err}")


if __name__ == "__main__":
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True, timeout_keep_alive=300000)
