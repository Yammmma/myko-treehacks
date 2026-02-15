import os
import json
import time
from openai import AsyncOpenAI

class Agent:
    def __init__(self, tracker, debug: bool = True):
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            raise ValueError("OPENAI_API_KEY not set")

        self.client = AsyncOpenAI(api_key=api_key)
        self.tracker = tracker
        self.debug = debug

        self.tools = [{
            "type": "function",
            "function": {
                "name": "update_tracking",
                "description": (
                    "Add or remove cell segmentation overlays on the live microscope feed. "
                    "The backend detects stained cells/structures via computer vision. "
                    "Query strings can include a region like 'bottom', 'top', 'left', 'right' "
                    "to limit segmentation to that part of the slide. "
                    "Examples: 'cells at the bottom', 'muscle cells', 'all cells'."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "add": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Descriptive queries for what to segment. Include region hints if the user specifies a location (e.g. 'cells at the bottom', 'tissue on the left')."
                        },
                        "remove": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Queries whose overlays should be removed."
                        }
                    }
                }
            }
        }]

        self.messages = [
            {
                "role": "system",
                "content": (
                    "You are Myko, an expert AI histopathology assistant with deep "
                    "knowledge of cell morphology, tissue architecture, and clinical "
                    "pathology. You speak with authority and technical precision. "
                    "You ALWAYS provide a definitive, detailed answer — never say you "
                    "'can't' identify something or need more information. Analyse the "
                    "image you are given and describe what you observe confidently.\n\n"
                    "TOOL USAGE RULES — follow these strictly:\n"
                    "• ONLY call 'update_tracking' when the user gives an explicit ACTION "
                    "command to segment, highlight, overlay, track, mark, show, "
                    "or remove cells on the live feed.\n"
                    "  Examples: 'segment the cells at the bottom', "
                    "'highlight all cells', 'show the muscle fibers', "
                    "'remove the overlay'.\n"
                    "• NEVER call the tool for questions or analysis requests "
                    "such as 'what cells are in this image?', 'describe the "
                    "tissue', 'how many cells?', 'what do you see?'. "
                    "For those, analyse the image directly and give a confident, "
                    "technical answer.\n\n"
                    "When calling the tool, include spatial hints from the user's "
                    "request in the query string (e.g. 'cells at the bottom', "
                    "'tissue on the right'). To segment everything use 'all cells'.\n\n"
                    "IMPORTANT: The current microscope image is ALWAYS attached to "
                    "every message. You can always see it. NEVER say you cannot see "
                    "the image, never ask the user to provide or send an image, "
                    "and never say you need additional input. Just analyse what you see.\n\n"
                    "To remove overlays, use the 'remove' field with the same query."
                )
            }
        ]

    async def query(self, prompt: str, frame_b64: str | None = None) -> str:
        if self.debug:
            print(f"ℹ️ Agent received prompt: {prompt[:100]}{'...' if len(prompt) > 100 else ''}")

        # Auto-attach the latest WebSocket frame if the caller didn't provide one
        if not frame_b64 and self.tracker.latest_frame is not None:
            import base64, cv2
            _, buf = cv2.imencode('.jpg', self.tracker.latest_frame)
            frame_b64 = "data:image/jpeg;base64," + base64.b64encode(buf).decode('utf-8')
            if self.debug:
                print("ℹ️ Auto-attached latest frame for vision")

        current_message = {"role": "user", "content": prompt}
        if frame_b64:
            current_message["content"] = [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": frame_b64}}
            ]

        start_time = time.time()
        try:
            response = await self.client.chat.completions.create(
                model="gpt-4o",
                messages=self.messages + [current_message],
                tools=self.tools,
                tool_choice="auto"
            )
        except Exception as e:
            print(f"⚠️ Agent query error: {e}")
            raise e

        elapsed = time.time() - start_time
        if self.debug:
            print(f"ℹ️ Agent query processed in {elapsed:.3f}s")

        message = response.choices[0].message

        # Execute tool calls
        if message.tool_calls:
            tool_results = []
            for tool_call in message.tool_calls:
                if tool_call.function.name == "update_tracking":
                    args = json.loads(tool_call.function.arguments)
                    result = await self.tracker.handle_tool_call(
                        add=args.get("add"),
                        remove=args.get("remove"),
                        frame_b64=frame_b64
                    )
                    tool_results.append(result)
                    if self.debug:
                        print(f"✅ Tool call: {args} → {result}")

            # Add the assistant message + tool results, then get a final response
            self.messages.append(current_message)
            self.messages.append({
                "role": "assistant",
                "content": message.content,
                "tool_calls": [
                    {"id": tc.id, "type": "function",
                     "function": {"name": tc.function.name,
                                  "arguments": tc.function.arguments}}
                    for tc in message.tool_calls
                ],
            })
            for i, tool_call in enumerate(message.tool_calls):
                self.messages.append({
                    "role": "tool",
                    "tool_call_id": tool_call.id,
                    "content": tool_results[i] if i < len(tool_results) else "",
                })

            # Let the model summarise the result for the user
            followup = await self.client.chat.completions.create(
                model="gpt-4o",
                messages=self.messages,
            )
            assistant_text = followup.choices[0].message.content or "; ".join(tool_results)
            self.messages.append({"role": "assistant", "content": assistant_text})
        else:
            assistant_text = message.content or "I processed your request."
            self.messages.append(current_message)
            self.messages.append({"role": "assistant", "content": assistant_text})

        if self.debug:
            print(f"ℹ️ Agent response: {assistant_text[:100]}{'...' if len(assistant_text) > 100 else ''}")

        return assistant_text
