import asyncio
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from agent import Agent
from tracker import Tracker
import json

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Init Global Instances
tracker = Tracker()
agent = Agent(tracker, debug=True)

class ChatRequest(BaseModel):
    prompt: str
    frame: str | None = None

@app.post("/query")
async def query_endpoint(request: ChatRequest):
    # Pass prompt to agent. Agent will use tracker.latest_frame if request.frame is None
    response = await agent.query(request.prompt, request.frame)
    return {"response": response}

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    print("✅ WS Connected")

    try:
        while True:
            # 1. Receive Frame
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                raise WebSocketDisconnect()

            base64_frame = None
            if "text" in message:
                try:
                    data = json.loads(message["text"])
                    base64_frame = data.get("frame")
                except:
                    base64_frame = message["text"] # Handle raw string case

            if base64_frame:
                # 2. Process (Decode -> Store -> Overlay -> Encode)
                edited_frame = tracker.process_frame(base64_frame)
                
                # 3. Send Back
                await websocket.send_text(edited_frame)

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
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True)
