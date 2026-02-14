import os
import io
import base64
import openai
from PIL import Image

class Agent:
    def __init__(self):
        # 1. Initialize OpenAI Client
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            raise ValueError("OPENAI_API_KEY is not set!")
        
        self.client = openai.OpenAI(api_key=api_key)
        
        # 2. Initialize Chat History
        self.messages = [
            {"role": "system", "content": "You are a helpful assistant. Be concise."},
        ]
    
    def query(self, user_input: str, frame: str) -> str:
        """
        Takes a text query and a string, updates history, and returns response.
        """
        
        # Add User Message to History
        self.messages.append({
            "role": "user",
            "content": [
                {"type": "text", "text": user_input},
                {
                    "type": "image_url",
                    "image_url": {"url": f"{frame}"},
                },
            ],
        })

        # Call API
        try:
            response = self.client.chat.completions.create(
                model="gpt-4o", 
                messages=self.messages,
            )
        except Exception as e:
            # Rollback history on failure so we don't get stuck with a hanging user message
            self.messages.pop()
            raise e

        # Add Assistant Response to History
        assistant_text = response.choices[0].message.content
        self.messages.append({"role": "assistant", "content": assistant_text})

        return assistant_text