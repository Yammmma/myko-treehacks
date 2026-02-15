import os
import base64
import asyncio
import traceback

import cv2
import numpy as np


class Tracker:
    def __init__(self):
        self.active_masks = {}        # {query: {"contours", "color", "count"}}
        self.latest_frame = None      # last raw frame from the WebSocket
        print("✅ Tracker ready (OpenCV segmentation)")

    # ------------------------------------------------------------------ #
    #  Core segmentation — pure OpenCV, works on any histology image       #
    # ------------------------------------------------------------------ #

    def _segment(self, img_bgr: np.ndarray,
                 region: str = "all") -> list[np.ndarray]:
        """Segment individual cells via boundary subtraction.

        Strategy:
        1. Exclude white/black background via saturation
        2. Tissue mask from saturation (stained tissue = high sat)
        3. Detect bright intercellular gaps via adaptive threshold on gray
        4. Subtract gaps from tissue → connected components = cells
        5. Smooth contours
        """
        h, w = img_bgr.shape[:2]

        # --- 1. Region crop ----------------------------------------------
        roi_mask = np.ones((h, w), dtype=np.uint8) * 255
        rl = region.lower()
        if "bottom" in rl:
            roi_mask[:h // 2, :] = 0
        elif "top" in rl:
            roi_mask[h // 2:, :] = 0
        elif "left" in rl:
            roi_mask[:, w // 2:] = 0
        elif "right" in rl:
            roi_mask[:, :w // 2] = 0

        # --- 2. Colour spaces & kernels ----------------------------------
        hsv  = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2HSV)
        gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
        sat  = hsv[:, :, 1]
        val  = hsv[:, :, 2]

        k3 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        k5 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))

        # --- 3. Exclude slide background ---------------------------------
        # Background = low saturation AND high brightness (white slide)
        bg = ((sat < 30) & (val > 200)).astype(np.uint8) * 255
        # Also exclude very dark areas (out-of-FOV black)
        dark = (val < 30).astype(np.uint8) * 255
        bg = bg | dark
        bg = cv2.dilate(bg, k5, iterations=4)  # generous margin
        fg = cv2.bitwise_and(cv2.bitwise_not(bg), roi_mask)

        # --- 4. Tissue mask from saturation ------------------------------
        sat_blur = cv2.GaussianBlur(sat, (7, 7), 0)
        # Fixed threshold — any meaningfully stained pixel
        _, tissue = cv2.threshold(sat_blur, 35, 255, cv2.THRESH_BINARY)
        tissue = cv2.bitwise_and(tissue, fg)

        # Close small holes, remove specks
        tissue = cv2.morphologyEx(tissue, cv2.MORPH_CLOSE, k3, iterations=2)
        tissue = cv2.morphologyEx(tissue, cv2.MORPH_OPEN, k3, iterations=1)

        tissue_area = cv2.countNonZero(tissue)
        print(f"  🔬 Tissue: {tissue_area} px / {h*w}")
        if tissue_area < 500:
            return []

        # --- 5. Detect intercellular gaps (bright lines between cells) ----
        gray_blur = cv2.GaussianBlur(gray, (5, 5), 0)

        # Adaptive threshold: pixels brighter than local mean → gap
        # blockSize=25 ~ cell-diameter scale; C=3 = slight offset
        gaps = cv2.adaptiveThreshold(
            gray_blur, 255, cv2.ADAPTIVE_THRESH_MEAN_C,
            cv2.THRESH_BINARY, blockSize=25, C=3)

        # Only keep gaps within/near tissue
        tissue_padded = cv2.dilate(tissue, k3, iterations=2)
        gaps = cv2.bitwise_and(gaps, tissue_padded)

        # Thicken gaps so they fully separate touching cells
        gaps = cv2.dilate(gaps, k3, iterations=1)

        # --- 6. Split: subtract gaps from tissue -------------------------
        cells_mask = cv2.bitwise_and(tissue, cv2.bitwise_not(gaps))

        # Light cleanup — remove tiny fragments but don't close (re-merge)
        cells_mask = cv2.morphologyEx(cells_mask, cv2.MORPH_OPEN, k3,
                                      iterations=1)

        # Blur the mask slightly before contour extraction → smoother edges
        cells_smooth = cv2.GaussianBlur(cells_mask, (5, 5), 0)
        _, cells_smooth = cv2.threshold(cells_smooth, 127, 255,
                                        cv2.THRESH_BINARY)

        # --- 7. Connected components → contours --------------------------
        n_labels, labels = cv2.connectedComponents(cells_smooth)

        min_area = max(30, int(h * w * 0.0001))
        max_area = int(h * w * 0.015)  # individual cell < 1.5% of image

        contours_out = []
        for lbl in range(1, n_labels):
            lbl_mask = (labels == lbl).astype(np.uint8) * 255
            cnts, _ = cv2.findContours(lbl_mask, cv2.RETR_EXTERNAL,
                                       cv2.CHAIN_APPROX_SIMPLE)
            for c in cnts:
                area = cv2.contourArea(c)
                if min_area < area < max_area:
                    contours_out.append(c)

        # --- 8. Smooth contours ------------------------------------------
        smoothed = []
        for c in contours_out:
            perim = cv2.arcLength(c, True)
            approx = cv2.approxPolyDP(c, 0.015 * perim, True)
            if len(approx) >= 4:
                smoothed.append(approx)

        print(f"  📊 Segmented {len(smoothed)} individual cells")
        return smoothed

    # ------------------------------------------------------------------ #
    #  Keyword → region / colour                                           #
    # ------------------------------------------------------------------ #

    COLORS = {
        "red":    (0, 0, 255),
        "green":  (0, 255, 0),
        "blue":   (255, 0, 0),
        "yellow": (0, 255, 255),
        "cyan":   (255, 255, 0),
        "orange": (0, 165, 255),
    }

    @staticmethod
    def _parse_region(query: str) -> str:
        q = query.lower()
        for kw in ["bottom", "top", "left", "right"]:
            if kw in q:
                return kw
        return "all"

    def _pick_color(self, query: str) -> tuple:
        q = query.lower()
        for name, bgr in self.COLORS.items():
            if name in q:
                return bgr
        # cycle through colours based on how many masks exist
        palette = list(self.COLORS.values())
        return palette[len(self.active_masks) % len(palette)]

    # ------------------------------------------------------------------ #
    #  Public API (called by Agent)                                        #
    # ------------------------------------------------------------------ #

    async def add_mask(self, query: str,
                       frame_b64: str | None = None) -> str:
        """Segment the current image, store contours for overlay."""
        image = None

        if self.latest_frame is not None:
            image = self.latest_frame
        elif frame_b64:
            raw = frame_b64.split(',', 1)[-1] if ',' in frame_b64 else frame_b64
            try:
                buf = np.frombuffer(base64.b64decode(raw), np.uint8)
                image = cv2.imdecode(buf, cv2.IMREAD_COLOR)
            except Exception as e:
                print(f"⚠️ Failed to decode frame_b64: {e}")

        if image is None:
            return "No image available — send a frame over the WebSocket first."

        print(f"🔬 Segmenting for: '{query}'")
        region = self._parse_region(query)
        color  = self._pick_color(query)

        contours = await asyncio.to_thread(self._segment, image, region)

        if not contours:
            return f"No cells detected for '{query}'."

        self.active_masks[query] = {
            "contours": contours,
            "color": color,
            "count": len(contours),
        }
        result = f"Segmented {len(contours)} cells for '{query}'"
        print(f"  ✅ {result}")
        return result

    def remove_mask(self, query: str) -> str:
        removed = [k for k in list(self.active_masks)
                   if query.lower() in k.lower()]
        for k in removed:
            del self.active_masks[k]
        return (f"Removed: {', '.join(removed)}" if removed
                else f"No active masks matching '{query}'")

    def clear_masks(self) -> str:
        self.active_masks.clear()
        return "All masks cleared."

    async def handle_tool_call(self, add=None, remove=None,
                               frame_b64=None) -> str:
        results = []
        if remove:
            for q in remove:
                results.append(self.remove_mask(q))
        if add:
            for q in add:
                results.append(await self.add_mask(q, frame_b64))
        return "; ".join(results) if results else "No action taken."

    # ------------------------------------------------------------------ #
    #  Frame overlay (WebSocket hot-path)                                  #
    # ------------------------------------------------------------------ #

    def process_frame(self, b64_frame: str) -> str:
        """Decode → store latest → draw contours → encode."""
        try:
            buf = np.frombuffer(base64.b64decode(b64_frame), np.uint8)
            img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
            if img is None:
                return b64_frame

            self.latest_frame = img.copy()

            if self.active_masks:
                overlay = img.copy()
                for query, md in self.active_masks.items():
                    color = md["color"]
                    contours = md["contours"]

                    # Draw filled contours with transparency
                    cv2.drawContours(overlay, contours, -1, color, cv2.FILLED)
                    # Draw outlines for crisp edges
                    cv2.drawContours(img, contours, -1, color, 1)

                img = cv2.addWeighted(overlay, 0.25, img, 0.75, 0)

            _, out_buf = cv2.imencode('.jpg', img)
            return base64.b64encode(out_buf).decode('utf-8')

        except Exception as e:
            print(f"⚠️ Frame error: {e}")
            traceback.print_exc()
            return b64_frame
