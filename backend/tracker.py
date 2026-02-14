import threading
import base64
import io
import logging
import numpy as np
import cv2
from PIL import Image
from sam2_wrapper import SAM2Wrapper

logger = logging.getLogger(__name__)


class Tracker:
    _instance = None
    _lock = threading.Lock()

    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super(Tracker, cls).__new__(cls)
                    cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return

        self.sam2 = SAM2Wrapper()
        self.active_targets = {}
        self.lock = threading.Lock()  # Guards both active_targets AND sam2 model access
        self._initialized = True

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _clean_b64(frame_b64: str) -> str:
        """Strip quotes, data-URI prefix, and escaped slashes from a base64 string."""
        clean = frame_b64.strip().replace('"', '').replace('\\/', '/')
        if "," in clean:
            clean = clean.split(",", 1)[1]
        return clean

    def _decode_frame(self, frame_b64: str) -> Image.Image:
        """Decode a base64 frame string into a PIL RGB Image."""
        clean = self._clean_b64(frame_b64)
        image_data = base64.b64decode(clean)
        return Image.open(io.BytesIO(image_data)).convert("RGB")

    # ------------------------------------------------------------------
    # Agent-facing methods (called from Agent during /query)
    # ------------------------------------------------------------------

    def get_agnostic_masks(self, frame_b64: str):
        """Generate all candidate masks for the frame.

        Acquires the model lock so this cannot race with process_frame.
        """
        image = self._decode_frame(frame_b64)
        with self.lock:
            masks = self.sam2.get_agnostic_masks(image)
        return masks, image

    def add_target(self, mask_id: int, mask_data: dict, label: str):
        with self.lock:
            seg = mask_data['segmentation']
            y_indices, x_indices = np.where(seg)
            if len(x_indices) == 0:
                logger.warning(f"Mask {mask_id} has no pixels — skipping.")
                return

            center_x = int(np.mean(x_indices))
            center_y = int(np.mean(y_indices))

            # Ensure the seed point is actually ON the mask (handles concave / donut shapes)
            if not seg[center_y, center_x]:
                distances = (x_indices - center_x) ** 2 + (y_indices - center_y) ** 2
                closest_idx = np.argmin(distances)
                center_x = int(x_indices[closest_idx])
                center_y = int(y_indices[closest_idx])

            points = np.array([[center_x, center_y]], dtype=np.float32)
            labels = np.array([1], dtype=np.int32)

            self.active_targets[mask_id] = {
                "label": label,
                "color": tuple(np.random.randint(0, 255, 3).tolist()),
                "points": points,
                "labels": labels,
                "last_logits": None
            }
            logger.info(f"Tracker: Added target {mask_id} ('{label}') at ({center_x}, {center_y})")

    def remove_target(self, mask_id: int):
        with self.lock:
            removed = self.active_targets.pop(mask_id, None)
            if removed:
                logger.info(f"Tracker: Removed target {mask_id}")

    def clear_targets(self):
        with self.lock:
            self.active_targets.clear()
            logger.info("Tracker: Cleared all targets")

    # ------------------------------------------------------------------
    # WebSocket-facing method (called every frame from /ws)
    # ------------------------------------------------------------------

    def process_frame(self, frame_b64: str) -> str:
        # Fast path: no targets → return raw base64 unchanged (skip SAM2 entirely)
        with self.lock:
            has_targets = bool(self.active_targets)
        if not has_targets:
            return self._clean_b64(frame_b64)

        try:
            image_pil = self._decode_frame(frame_b64)
            frame_np = np.array(image_pil)
        except Exception as e:
            raise ValueError(f"Frame decode failed: {e}")

        with self.lock:
            # Re-check after acquiring lock (target may have been removed)
            if not self.active_targets:
                return self._clean_b64(frame_b64)

            # Encode image ONCE for all targets (expensive encoder pass)
            self.sam2.predictor.set_image(frame_np)

            # Keep a clean copy for display — SAM2 always reads the original encoding
            display_np = frame_np.copy()

            for obj_id, target in self.active_targets.items():
                mask, logits = self.sam2.predict_only(
                    previous_mask=target["last_logits"],
                    point_coords=target["points"] if target["last_logits"] is None else None,
                    point_labels=target["labels"] if target["last_logits"] is None else None
                )

                if mask is not None:
                    target["last_logits"] = logits

                    # Overlay colored mask on the *display* frame (not inference input)
                    color = target["color"]
                    colored_mask = np.zeros_like(display_np)
                    colored_mask[mask > 0] = color
                    display_np = cv2.addWeighted(display_np, 1.0, colored_mask, 0.5, 0)

                    y, x = np.where(mask)
                    if len(y) > 0:
                        top_y, top_x = int(np.min(y)), int(np.min(x))
                        cv2.putText(display_np, target["label"],
                                    (top_x, top_y - 10), cv2.FONT_HERSHEY_SIMPLEX,
                                    0.9, (255, 255, 255), 2)

        out_pil = Image.fromarray(display_np)
        buff = io.BytesIO()
        out_pil.save(buff, format="JPEG", quality=75)
        raw_b64 = base64.b64encode(buff.getvalue()).decode("utf-8")
        buff.close()
        return raw_b64