import uvicorn
import base64
import io
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from PIL import Image
from agent import Agent

app = FastAPI()

# Global Agent (Stateful)
agent = Agent()

class ChatRequest(BaseModel):
    prompt: str
    frame: str 

# Debugging handler for 422 errors
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    print(f"❌ 422 Validation Error: {exc.errors()}")
    print(request.headers.keys())
    body = await request.body()
    print(f"❌ Received Body: {body.decode()}")
    return JSONResponse(status_code=422, content={"detail": exc.errors()})

@app.post("/query")
def chat_endpoint(request: ChatRequest):
    print(f"✅ Received prompt: {request.prompt}")
    
    try:
        response_text = agent.query(request.prompt, request.frame)
        return {"response": response_text}
    except Exception as e:
        print(f"❌ Agent Error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)