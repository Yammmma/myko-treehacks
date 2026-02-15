import os
import json
import time
import re
from openai import AsyncOpenAI


class Agent:
    def __init__(self, segmenter, debug: bool = True):
        self.segmenter = segmenter
        self.debug = debug
        self.client = None  # lazily created on first query

        self.tools = [
            {
                "type": "function",
                "function": {
                    "name": "propose_masks",
                    "description": (
                        "Generate model-agnostic candidate masks from the current image. "
                        "Use this first for segmentation/highlight requests. Returns candidate indices and features."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": {
                                "type": "string",
                                "description": "Segmentation intent, such as 'red blood cells', 'all cells', or 'cells at bottom'."
                            },
                            "backend": {
                                "type": "string",
                                "enum": ["auto", "cellpose", "sam2", "opencv"],
                                "description": "Optional backend override for mask proposals. Prefer auto unless user asks otherwise."
                            }
                        },
                        "required": ["query"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "apply_masks",
                    "description": (
                        "Select and render a subset of candidate masks by index after propose_masks has been called."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "indices": {
                                "type": "array",
                                "items": {"type": "integer"},
                                "description": "Indices of candidate masks to render."
                            },
                            "query": {
                                "type": "string",
                                "description": "Optional label for this selected mask set."
                            }
                        },
                        "required": ["indices"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "clear_masks",
                    "description": "Remove all active rendered masks.",
                    "parameters": {
                        "type": "object",
                        "properties": {}
                    }
                }
            }
        ]

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
                    "TOOL USAGE RULES:\n"
                    "• ONLY call tools when the user explicitly asks to "
                    "segment, highlight, show, mark, or overlay structures.\n"
                    "  Examples: 'segment the cells', 'highlight all cells', "
                    "'show me the tissue boundaries'.\n"
                    "• For segmentation requests, ALWAYS do this sequence:\n"
                    "  1) call 'propose_masks' first,\n"
                    "  2) inspect returned candidates,\n"
                    "  3) call 'apply_masks' with selected indices.\n"
                    "• NEVER call any tool for counting or quantitative analysis "
                    "questions like 'how many', 'count', 'number of', or 'total'. "
                    "For those, answer directly from visual analysis only.\n"
                    "• The microscope image is ALWAYS attached to every message. "
                    "You can see it. Never ask for an image or say you need more info.\n"
                    "• To remove overlays, call 'clear_masks'.\n\n"
                    "Be confident and technical in your responses."
                )
            }
        ]

    @staticmethod
    def _is_counting_prompt(prompt: str) -> bool:
        p = (prompt or "").lower()
        patterns = [
            r"\bhow many\b",
            r"\bcount\b",
            r"\bnumber of\b",
            r"\btotal\b",
            r"\bquantity\b",
        ]
        return any(re.search(pattern, p) for pattern in patterns)

    def _get_client(self) -> AsyncOpenAI:
        if self.client is None:
            api_key = os.getenv("OPENAI_API_KEY")
            if not api_key:
                raise ValueError("OPENAI_API_KEY not set — export it before sending a query")
            self.client = AsyncOpenAI(api_key=api_key)
        return self.client

    async def _completion(self, messages: list, tools: list | None = None):
        kwargs: dict = {"model": "gpt-4o", "messages": messages}
        if tools:
            kwargs["tools"] = tools
            kwargs["tool_choice"] = "auto"
        response = await self._get_client().chat.completions.create(**kwargs)
        return response.choices[0].message

    async def query(self, prompt: str, frame_b64: str | None = None) -> str:
        if self.debug:
            print(f"ℹ️ Agent received prompt: {prompt[:100]}{'...' if len(prompt) > 100 else ''}")

        # Auto-attach the latest WebSocket frame if the caller didn't provide one
        if not frame_b64 and self.segmenter.latest_b64:
            frame_b64 = "data:image/jpeg;base64," + self.segmenter.latest_b64
            if self.debug:
                print("ℹ️ Auto-attached latest frame for vision")

        current_message = {"role": "user", "content": prompt}
        if frame_b64:
            current_message["content"] = [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": frame_b64}}
            ]

        is_counting = self._is_counting_prompt(prompt)
        if self.debug and is_counting:
            print("ℹ️ Counting prompt detected: tools disabled for this turn")

        self.messages.append(current_message)

        start_time = time.time()
        try:
            message = await self._completion(
                self.messages,
                tools=None if is_counting else self.tools,
            )
        except Exception as e:
            print(f"⚠️ Agent query error: {e}")
            raise e

        elapsed = time.time() - start_time
        if self.debug:
            print(f"ℹ️ Agent query processed in {elapsed:.3f}s")

        rounds = 0
        tool_results: list[str] = []
        while (not is_counting) and message.tool_calls and rounds < 4:
            rounds += 1
            self.messages.append({
                "role": "assistant",
                "content": message.content,
                "tool_calls": [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        },
                    }
                    for tc in message.tool_calls
                ],
            })

            for tool_call in message.tool_calls:
                args = json.loads(tool_call.function.arguments or "{}")
                result = "No action taken."

                if tool_call.function.name == "propose_masks":
                    query = (args.get("query") or "all cells").strip()
                    backend = (args.get("backend") or "auto").strip().lower()
                    result = await self.segmenter.propose_masks(query, frame_b64, backend=backend)
                elif tool_call.function.name == "apply_masks":
                    indices = args.get("indices") or []
                    query = (args.get("query") or "selected masks").strip()
                    result = self.segmenter.apply_masks(indices, query=query)
                elif tool_call.function.name == "clear_masks":
                    result = self.segmenter.clear_masks()

                tool_results.append(result)
                self.messages.append({
                    "role": "tool",
                    "tool_call_id": tool_call.id,
                    "content": result,
                })
                if self.debug:
                    print(f"✅ Tool call: {tool_call.function.name} {args} → {result}")

            message = await self._completion(self.messages, tools=self.tools)

        assistant_text = message.content or ("; ".join(tool_results) if tool_results else "I processed your request.")
        self.messages.append({"role": "assistant", "content": assistant_text})

        if self.debug:
            print(f"ℹ️ Agent response: {assistant_text[:100]}{'...' if len(assistant_text) > 100 else ''}")

        return assistant_text
