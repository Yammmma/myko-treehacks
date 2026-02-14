import asyncio
import uvicorn
import base64
import json
import logging
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from agent import Agent
from tracker import Tracker

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

agent = Agent()
tracker = Tracker()

class ChatRequest(BaseModel):
    prompt: str
    frame: str

@app.post("/query")
async def chat_endpoint(request: ChatRequest):
    logger.info(f"POST /query received. Prompt: {request.prompt[:50]}...")
    try:
        response_text = await asyncio.to_thread(agent.query, request.prompt, request.frame)
        return {"response": response_text}
    except Exception as e:
        logger.error(f"Error in chat_endpoint: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

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
    logger.info("Starting server on 0.0.0.0:8000")
    uvicorn.run(app, host="0.0.0.0", port=8000)