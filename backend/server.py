import asyncio
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from agent import Agent
from tracker import Segmenter
import json
import base64
import asyncio

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Init Global Instances
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
    """Pull the base64 frame string out of a raw WS message."""
    if "text" in message:
        try:
            data = json.loads(message["text"])
            return data.get("frame")
        except Exception:
            return message["text"]
    elif "bytes" in message:
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

    # Shared slot — receiver always writes latest, processor reads it
    latest_frame: dict = {"data": None, "event": asyncio.Event()}

    async def receiver():
        """Tight loop: drain the socket, keep only the newest frame."""
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
            latest_frame["event"].set()  # unblock processor so it can exit
            raise

    async def processor():
        """Wait for a new frame, render with static masks if any."""
        try:
            while True:
                await latest_frame["event"].wait()
                latest_frame["event"].clear()

                frame = latest_frame["data"]
                if frame is None:
                    continue

                # Render static overlay if masks are active. Fail open per frame.
                try:
                    edited_frame = await asyncio.to_thread(segmenter.render_frame, frame)
                except Exception as render_err:
                    print(f"⚠️ Frame render error: {render_err}")
                    edited_frame = frame.split(',', 1)[-1] if ',' in frame else frame
                await websocket.send_text(edited_frame)
        except Exception:
            raise

    try:
        await asyncio.gather(receiver(), processor())
    except WebSocketDisconnect:
        print("❌ WS Disconnected")
    except Exception as e:
        print(f"⚠️ WS Error: {e}")

@app.websocket("/ws")
async def video_endpoint(websocket: WebSocket):
    await websocket.accept()
    logger.info("⚡ WebSocket Connected")
    
    frame_count = 0
    try:
        while True:
            message = await websocket.receive()
            frame_count += 1
            
            try:
                raw_input = ""
                if "text" in message:
                    raw_input = message["text"]
                elif "bytes" in message:
                    raw_input = message["bytes"].decode('utf-8')
                
                if not raw_input:
                    continue

                try:
                    payload = json.loads(raw_input)
                    image_data = payload.get("frame", "")
                except json.JSONDecodeError:
                    image_data = raw_input

                # Log every 100th frame to avoid flooding the console
                if frame_count % 100 == 0:
                    logger.info(f"Processing frame #{frame_count}")

                processed_frame = await asyncio.to_thread(tracker.process_frame, image_data)
                await websocket.send_text(processed_frame)
                
            except Exception as frame_err:
                logger.warning(f"⚠️ Frame Error on frame {frame_count}: {frame_err}")
                continue
                
    except WebSocketDisconnect:
        logger.info("⚡ WebSocket Disconnected")
    except Exception as e:
        logger.error(f"❌ Fatal WebSocket Error: {e}", exc_info=True)

if __name__ == "__main__":
<<<<<<< Updated upstream
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True)
=======
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True, timeout_keep_alive=300000)
>>>>>>> Stashed changes
