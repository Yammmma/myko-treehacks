import os
import io
import base64
import json
import logging
import openai
from PIL import Image, ImageDraw
from tracker import Tracker

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

MAX_AGENT_ITERATIONS = 10
MAX_CANDIDATE_MASKS = 25
MIN_MASK_AREA_RATIO = 0.001   # Filter masks smaller than 0.1% of image
MAX_MASK_AREA_RATIO = 0.90    # Filter masks larger than 90% of image (background)


class Agent:
    def __init__(self):
        logger.info("Initializing Agent...")
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            logger.error("OPENAI_API_KEY environment variable is missing.")
            raise ValueError("OPENAI_API_KEY is not set!")

        self.client = openai.OpenAI(api_key=api_key)
        self.tracker = Tracker()

        self.system_message = {
            "role": "system",
            "content": (
                "You are Myko, a bio-image analyst agent that uses SAM 2 for object "
                "segmentation and tracking under a microscope.\n\n"
                "Workflow:\n"
                "1. When the user asks you to track or identify something, call "
                "`get_candidates` to generate all segmentable masks from the current frame.\n"
                "2. You will receive a list of candidate masks with bounding-box coordinates "
                "and an annotated image with numbered boxes. Analyze them to determine which "
                "mask ID(s) correspond to the user's request.\n"
                "3. Call `track_object` with the correct mask_id and a descriptive label.\n"
                "4. Confirm to the user that tracking has started.\n\n"
                "If the user asks a general question about the image (not tracking), "
                "answer directly without calling tools."
            )
        }

        self.tools = [
            {
                "type": "function",
                "function": {
                    "name": "get_candidates",
                    "description": (
                        "Run automatic segmentation on the current frame to discover all "
                        "segmentable objects. Returns a text list of candidates with bounding "
                        "boxes and an annotated image with numbered IDs."
                    ),
                    "parameters": {"type": "object", "properties": {}, "required": []}
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "track_object",
                    "description": (
                        "Start real-time tracking for a specific mask by its ID number. "
                        "Use this after reviewing the annotated candidates image."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "mask_id": {
                                "type": "integer",
                                "description": "The numeric ID of the mask to track (from the annotated image)."
                            },
                            "label": {
                                "type": "string",
                                "description": "A short descriptive label for the tracked object (e.g. 'red blood cell', 'nucleus')."
                            }
                        },
                        "required": ["mask_id", "label"]
                    }
                }
            }
        ]
        self.current_candidates = {}

    def query(self, user_input: str, frame_b64: str) -> str:
        logger.info(f"Received query: {user_input}")

        # Ensure data URI prefix for GPT-4o vision
        if not frame_b64.startswith("data:image"):
            frame_b64 = f"data:image/jpeg;base64,{frame_b64}"

        # --- Fresh conversation per query (prevents unbounded token growth) ---
        messages = [
            self.system_message,
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user_input},
                    {"type": "image_url", "image_url": {"url": frame_b64}}
                ],
            }
        ]
        self.current_candidates = {}
        pending_annotated_b64 = None  # Image to inject after tool results

        for iteration in range(MAX_AGENT_ITERATIONS):
            logger.info(f"Agent iteration {iteration + 1}/{MAX_AGENT_ITERATIONS}")
            response = self.client.chat.completions.create(
                model="gpt-4o",
                messages=messages,
                tools=self.tools,
                tool_choice="auto"
            )

            msg = response.choices[0].message
            messages.append(msg)

            if not msg.tool_calls:
                logger.info("No tool calls returned. Ending loop.")
                return msg.content or "I couldn't generate a response."

            # --- Process every tool call in this response ---
            for tool_call in msg.tool_calls:
                fn_name = tool_call.function.name
                args = json.loads(tool_call.function.arguments)
                logger.info(f"Tool Call: {fn_name} with args: {args}")

                if fn_name == "get_candidates":
                    raw_masks, original_img = self.tracker.get_agnostic_masks(frame_b64)

                    # Filter by area to remove noise and background
                    image_area = original_img.width * original_img.height
                    filtered = [
                        m for m in raw_masks
                        if MIN_MASK_AREA_RATIO * image_area <= m['area'] <= MAX_MASK_AREA_RATIO * image_area
                    ]
                    # Sort by quality and cap count
                    filtered.sort(key=lambda m: m.get('predicted_iou', 0), reverse=True)
                    filtered = filtered[:MAX_CANDIDATE_MASKS]

                    logger.info(f"Filtered to {len(filtered)} candidates from {len(raw_masks)} raw masks.")

                    # Annotate image with numbered bounding boxes
                    annotated_img = original_img.copy()
                    draw = ImageDraw.Draw(annotated_img)
                    self.current_candidates = {}

                    descriptions = []
                    for i, mask_data in enumerate(filtered):
                        mask_id = i + 1
                        self.current_candidates[mask_id] = mask_data
                        x, y, w, h = mask_data['bbox']
                        draw.rectangle([int(x), int(y), int(x + w), int(y + h)], outline="red", width=2)
                        draw.text((int(x), int(y) - 12), str(mask_id), fill="yellow")
                        descriptions.append(
                            f"  ID {mask_id}: bbox=({int(x)},{int(y)},{int(w)},{int(h)}), area={mask_data['area']}"
                        )

                    buff = io.BytesIO()
                    annotated_img.save(buff, format="JPEG", quality=85)
                    annotated_b64 = base64.b64encode(buff.getvalue()).decode('utf-8')
                    buff.close()

                    summary = f"Found {len(filtered)} candidate masks:\n" + "\n".join(descriptions)

                    # Tool result MUST be a string (not multimodal)
                    messages.append({
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "content": summary
                    })
                    # Queue annotated image for injection after all tool results
                    pending_annotated_b64 = annotated_b64

                elif fn_name == "track_object":
                    mid = args["mask_id"]
                    label = args.get("label", f"object_{mid}")
                    if mid in self.current_candidates:
                        self.tracker.add_target(mid, self.current_candidates[mid], label)
                        tool_result = f"Tracking started for mask ID {mid} with label '{label}'."
                        logger.info(f"Successfully started tracking for mask_id {mid}.")
                    else:
                        available = list(self.current_candidates.keys())
                        tool_result = f"ID {mid} not found. Available IDs: {available}"
                        logger.warning(f"mask_id {mid} not found. Available: {available}")

                    messages.append({
                        "role": "tool", "tool_call_id": tool_call.id, "content": tool_result
                    })

                else:
                    messages.append({
                        "role": "tool", "tool_call_id": tool_call.id,
                        "content": f"Unknown function: {fn_name}"
                    })

            # After ALL tool results for this turn, inject the annotated image
            # as a user message so GPT-4o can actually see it
            if pending_annotated_b64:
                messages.append({
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "Here is the annotated image with numbered mask candidates. Select the correct one to track."},
                        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{pending_annotated_b64}"}}
                    ]
                })
                pending_annotated_b64 = None

        logger.warning("Agent hit max iterations without resolving.")
        return "I wasn't able to complete the analysis. Please try again with a simpler request."