import base64
import asyncio
import json
import cv2
import numpy as np

try:
    from scipy import ndimage as ndi
    from skimage import segmentation, feature
    HAS_SKIMAGE = True
except Exception:
    ndi = None
    segmentation = None
    feature = None
    HAS_SKIMAGE = False


class Segmenter:
    """Simple static segmentation - no tracking, just segment and render."""
    
    def __init__(self):
        self.active_masks = []        # List of {contours, color, query} dicts
        self.latest_proposals = []    # List of {contour, area, circularity, center, bbox, score}
        self._latest_b64 = None       # raw base64 (no data-uri prefix)
        self._jpeg_quality = 75
        self._has_skimage = HAS_SKIMAGE
        
        # Color palette for overlays
        self.colors = [
            (0, 255, 0),      # Green
            (0, 0, 255),      # Red
            (255, 0, 0),      # Blue
            (0, 255, 255),    # Yellow
            (255, 0, 255),    # Magenta
            (255, 255, 0),    # Cyan
            (0, 165, 255),    # Orange
        ]
        self.color_idx = 0
        
        backend = "skimage+opencv" if self._has_skimage else "opencv-only"
        print(f"✅ Segmenter ready (static masks, no tracking, backend={backend})")

    @staticmethod
    def _sanitize_contour(contour: np.ndarray) -> np.ndarray | None:
        if contour is None:
            return None
        contour = np.asarray(contour)
        if contour.ndim == 2 and contour.shape[1] == 2:
            contour = contour.reshape(-1, 1, 2)
        if contour.ndim != 3 or contour.shape[1] != 1 or contour.shape[2] != 2:
            return None

        contour = contour.astype(np.int32)
        if len(contour) < 3:
            return None

        area = float(cv2.contourArea(contour))
        if area <= 8.0:
            return None

        x, y, w, h = cv2.boundingRect(contour)
        if w <= 1 or h <= 1:
            return None

        aspect = max(w, h) / max(1.0, min(w, h))
        if aspect > 16.0:
            return None

        return contour

    @staticmethod
    def _contours_to_binary_mask(h: int, w: int, contours: list[np.ndarray]) -> np.ndarray:
        mask = np.zeros((h, w), dtype=np.uint8)
        valid = []
        for contour in contours:
            sanitized = Segmenter._sanitize_contour(contour)
            if sanitized is not None:
                valid.append(sanitized)
        if valid:
            cv2.drawContours(mask, valid, -1, 255, thickness=cv2.FILLED)
        return mask

    @staticmethod
    def _contour_features(contour: np.ndarray) -> dict:
        area = float(cv2.contourArea(contour))
        perimeter = float(cv2.arcLength(contour, True))
        circularity = float((4.0 * np.pi * area) / (perimeter * perimeter)) if perimeter > 0 else 0.0
        x, y, w, h = cv2.boundingRect(contour)
        M = cv2.moments(contour)
        if M["m00"] > 0:
            cx = int(M["m10"] / M["m00"])
            cy = int(M["m01"] / M["m00"])
        else:
            cx = x + w // 2
            cy = y + h // 2
        return {
            "area": area,
            "circularity": circularity,
            "center": [int(cx), int(cy)],
            "bbox": [int(x), int(y), int(w), int(h)],
        }

    @staticmethod
    def _query_score(query: str, feat: dict) -> float:
        q = (query or "").lower()
        score = 0.0
        area = feat["area"]
        circularity = feat["circularity"]
        w = max(feat["bbox"][2], 1)
        h = max(feat["bbox"][3], 1)
        aspect = max(w, h) / max(1.0, min(w, h))

        score += min(1.0, area / 250.0)
        score += circularity

        if "red blood" in q or "rbc" in q:
            score += 1.3 * circularity
            if 40.0 <= area <= 700.0:
                score += 0.8
            if aspect <= 1.5:
                score += 0.5
        elif "all" in q or "cell" in q:
            score += 0.3

        if "large" in q:
            score += min(1.2, area / 1200.0)
        if "small" in q:
            score += 0.9 if area < 250.0 else -0.3

        return float(score)

    @staticmethod
    def _region_mask(query: str, h: int, w: int) -> np.ndarray:
        mask = np.ones((h, w), dtype=np.uint8) * 255
        q = query.lower()
        if "bottom" in q:
            mask[:h // 2, :] = 0
        elif "top" in q:
            mask[h // 2:, :] = 0
        elif "left" in q:
            mask[:, w // 2:] = 0
        elif "right" in q:
            mask[:, :w // 2] = 0
        return mask

    @property
    def latest_b64(self) -> str | None:
        """Raw base64 string (no data-uri prefix)."""
        return self._latest_b64

    @staticmethod
    def _decode(raw_b64: str) -> np.ndarray | None:
        """Decode base64 string to BGR image."""
        try:
            buf = np.frombuffer(base64.b64decode(raw_b64), np.uint8)
            return cv2.imdecode(buf, cv2.IMREAD_COLOR)
        except Exception as e:
            print(f"⚠️ Decode error: {e}")
            return None

    def _encode(self, img: np.ndarray) -> str:
        """Encode BGR image to base64 string."""
        _, buffer = cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, self._jpeg_quality])
        return base64.b64encode(buffer).decode('utf-8')

    def _detect_microscope_mask(self, img: np.ndarray) -> np.ndarray:
        """Estimate valid field-of-view mask and suppress microscope rim."""
        h, w = img.shape[:2]
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

        threshold = max(8, int(np.percentile(gray, 15)))
        _, candidate = cv2.threshold(gray, threshold, 255, cv2.THRESH_BINARY)

        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13))
        candidate = cv2.morphologyEx(candidate, cv2.MORPH_CLOSE, kernel, iterations=2)

        num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(candidate, connectivity=8)
        if num_labels <= 1:
            return np.ones((h, w), dtype=np.uint8) * 255

        cx, cy = w // 2, h // 2
        center_label = labels[cy, cx]

        if center_label > 0:
            fov = (labels == center_label).astype(np.uint8) * 255
        else:
            areas = stats[1:, cv2.CC_STAT_AREA]
            best = int(np.argmax(areas)) + 1
            fov = (labels == best).astype(np.uint8) * 255

        if self._has_skimage and ndi is not None:
            fov = (ndi.binary_fill_holes(fov > 0).astype(np.uint8) * 255)

        erosion_px = max(3, int(min(h, w) * 0.02))
        erode_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * erosion_px + 1, 2 * erosion_px + 1))
        fov = cv2.erode(fov, erode_kernel, iterations=1)
        return fov

    @staticmethod
    def _remove_edge_connected(binary: np.ndarray, roi_mask: np.ndarray) -> np.ndarray:
        """Remove components touching the ROI edge band (usually rim artifacts)."""
        if not np.any(binary):
            return binary

        edge_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (17, 17))
        inner = cv2.erode(roi_mask, edge_kernel, iterations=1)
        edge_band = cv2.subtract(roi_mask, inner)

        num_labels, labels, stats, _ = cv2.connectedComponentsWithStats((binary > 0).astype(np.uint8), connectivity=8)
        cleaned = np.zeros_like(binary)
        for label in range(1, num_labels):
            area = stats[label, cv2.CC_STAT_AREA]
            if area <= 0:
                continue
            comp = (labels == label).astype(np.uint8)
            touch_ratio = (np.sum((comp > 0) & (edge_band > 0)) / area)
            if touch_ratio < 0.12:
                cleaned[comp > 0] = 255
        return cleaned

    def _build_candidate_mask(self, img: np.ndarray, roi_mask: np.ndarray) -> np.ndarray:
        """Build a robust foreground mask by combining multiple cues."""
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
        hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)

        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        gray_eq = clahe.apply(gray)
        gray_blur = cv2.GaussianBlur(gray_eq, (5, 5), 0)

        _, m_otsu = cv2.threshold(gray_blur, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        m_adapt = cv2.adaptiveThreshold(
            gray_blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv2.THRESH_BINARY_INV, 31, 4
        )

        s = hsv[:, :, 1]
        s_thr = int(np.percentile(s[roi_mask > 0], 60)) if np.any(roi_mask > 0) else 40
        m_sat = (s > max(25, s_thr)).astype(np.uint8) * 255

        a = lab[:, :, 1].astype(np.int16)
        b = lab[:, :, 2].astype(np.int16)
        med_a = int(np.median(a[roi_mask > 0])) if np.any(roi_mask > 0) else 128
        med_b = int(np.median(b[roi_mask > 0])) if np.any(roi_mask > 0) else 128
        stain_dev = np.abs(a - med_a) + np.abs(b - med_b)
        dev_thr = int(np.percentile(stain_dev[roi_mask > 0], 70)) if np.any(roi_mask > 0) else 30
        m_stain = (stain_dev > max(18, dev_thr)).astype(np.uint8) * 255

        votes = (m_otsu > 0).astype(np.uint8)
        votes += (m_adapt > 0).astype(np.uint8)
        votes += (m_sat > 0).astype(np.uint8)
        votes += (m_stain > 0).astype(np.uint8)
        combined = (votes >= 2).astype(np.uint8) * 255

        combined = cv2.bitwise_and(combined, roi_mask)
        kernel3 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        kernel5 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
        combined = cv2.morphologyEx(combined, cv2.MORPH_OPEN, kernel3, iterations=1)
        combined = cv2.morphologyEx(combined, cv2.MORPH_CLOSE, kernel5, iterations=2)
        combined = self._remove_edge_connected(combined, roi_mask)
        return combined

    def _watershed_labels(self, mask: np.ndarray) -> np.ndarray:
        if not np.any(mask):
            return np.zeros(mask.shape, dtype=np.int32)

        dist = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
        if float(dist.max()) <= 0:
            _, labels = cv2.connectedComponents(mask)
            return labels.astype(np.int32)

        if self._has_skimage and feature is not None and segmentation is not None and ndi is not None:
            peaks = feature.peak_local_max(
                dist,
                labels=(mask > 0),
                min_distance=7,
                exclude_border=False,
            )
            markers = np.zeros(mask.shape, dtype=np.int32)
            if peaks.size > 0:
                markers[peaks[:, 0], peaks[:, 1]] = np.arange(1, len(peaks) + 1)
            else:
                sure = (dist > (0.45 * dist.max())).astype(np.uint8)
                _, markers = cv2.connectedComponents(sure)
                markers = markers.astype(np.int32)

            labels = segmentation.watershed(-dist, markers, mask=(mask > 0))
            return labels.astype(np.int32)

        sure = (dist > (0.45 * dist.max())).astype(np.uint8) * 255
        _, labels = cv2.connectedComponents(sure)
        return labels.astype(np.int32)

    def _find_contours(self, img: np.ndarray, query: str) -> list:
        """Model-agnostic robust segmentation for microscopy and similar imagery."""
        h, w = img.shape[:2]

        fov_mask = self._detect_microscope_mask(img)
        region_mask = self._region_mask(query, h, w)
        roi_mask = cv2.bitwise_and(fov_mask, region_mask)

        candidate = self._build_candidate_mask(img, roi_mask)
        labels = self._watershed_labels(candidate)

        min_area = max(12, int(h * w * 0.000012))
        max_area = int(h * w * 0.03)

        rim_band = cv2.subtract(fov_mask, cv2.erode(
            fov_mask,
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)),
            iterations=1,
        ))

        filtered = []
        seen_centers = set()
        max_label = int(labels.max())
        for label in range(1, max_label + 1):
            inst = (labels == label).astype(np.uint8) * 255
            if not np.any(inst):
                continue

            cnts, _ = cv2.findContours(inst, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            if not cnts:
                continue
            contour = max(cnts, key=cv2.contourArea)
            area = cv2.contourArea(contour)
            if area < min_area or area > max_area:
                continue

            perimeter = cv2.arcLength(contour, True)
            if perimeter <= 0:
                continue
            circularity = float((4.0 * np.pi * area) / (perimeter * perimeter))
            if circularity < 0.20:
                continue

            hull = cv2.convexHull(contour)
            hull_area = max(cv2.contourArea(hull), 1.0)
            solidity = float(area / hull_area)
            if solidity < 0.55:
                continue

            c_mask = np.zeros((h, w), dtype=np.uint8)
            cv2.drawContours(c_mask, [contour], -1, 255, cv2.FILLED)
            edge_overlap = np.sum((c_mask > 0) & (rim_band > 0))
            if edge_overlap > 0.08 * area:
                continue

            M = cv2.moments(contour)
            if M["m00"] <= 0:
                continue
            cx = int((M["m10"] / M["m00"]) / 4) * 4
            cy = int((M["m01"] / M["m00"]) / 4) * 4
            key = (cx, cy)
            if key in seen_centers:
                continue
            seen_centers.add(key)

            eps = 0.007 * perimeter
            approx = cv2.approxPolyDP(contour, eps, True)
            filtered.append(approx)

        print(
            f"  ✅ Found {len(filtered)} valid objects "
            f"(candidate_pixels={int(np.count_nonzero(candidate))}, labels={max_label})"
        )
        return filtered

    def _store_proposals(self, contours: list[np.ndarray], query: str, limit: int = 200) -> list[dict]:
        proposals = []
        for contour in contours:
            contour = self._sanitize_contour(contour)
            if contour is None:
                continue
            feat = self._contour_features(contour)
            score = self._query_score(query, feat)
            proposals.append({
                "contour": contour,
                "area": feat["area"],
                "circularity": feat["circularity"],
                "center": feat["center"],
                "bbox": feat["bbox"],
                "score": score,
            })

        proposals.sort(key=lambda p: p["score"], reverse=True)
        self.latest_proposals = proposals[:max(1, limit)]
        return self.latest_proposals

    async def propose_masks(self, query: str, frame_b64: str | None = None) -> str:
        img = None
        if self._latest_b64:
            img = self._decode(self._latest_b64)

        if img is None and frame_b64:
            raw = frame_b64.split(',', 1)[-1] if ',' in frame_b64 else frame_b64
            img = self._decode(raw)

        if img is None:
            return "No image available - send a frame over the WebSocket first."

        print(f"🔬 Proposing masks for: '{query}'")
        contours = await asyncio.to_thread(self._find_contours, img, query)
        if not contours:
            self.latest_proposals = []
            return json.dumps({"count": 0, "candidates": []})

        proposals = self._store_proposals(contours, query)
        preview = []
        for i, p in enumerate(proposals[:60]):
            preview.append({
                "index": i,
                "area": round(float(p["area"]), 2),
                "circularity": round(float(p["circularity"]), 3),
                "center": p["center"],
                "bbox": p["bbox"],
                "score": round(float(p["score"]), 3),
            })

        return json.dumps({"count": len(proposals), "candidates": preview})

    def apply_masks(self, indices: list[int], query: str = "selected masks") -> str:
        if not self.latest_proposals:
            return "No proposals available. Call propose_masks first."

        valid = []
        seen = set()
        for idx in indices:
            if isinstance(idx, int) and 0 <= idx < len(self.latest_proposals) and idx not in seen:
                valid.append(idx)
                seen.add(idx)

        if not valid:
            return "No valid proposal indices provided."

        max_selected = 40
        valid = valid[:max_selected]

        selected = []
        for i in valid:
            contour = self._sanitize_contour(self.latest_proposals[i]["contour"])
            if contour is not None:
                selected.append(contour)

        if not selected:
            return "Selected indices did not contain valid filled contours."

        # Static behavior: replace prior rendered masks with the newly selected set.
        self.active_masks.clear()

        color = self.colors[self.color_idx % len(self.colors)]
        self.color_idx += 1

        raster = None
        if self._latest_b64:
            img = self._decode(self._latest_b64)
            if img is not None:
                h, w = img.shape[:2]
                raster = self._contours_to_binary_mask(h, w, selected)

        self.active_masks.append({
            "contours": selected,
            "color": color,
            "query": query,
            "raster": raster,
        })
        return f"Applied {len(selected)} mask(s) from indices {valid[:20]} for '{query}'."

    async def segment(self, query: str, frame_b64: str | None = None) -> str:
        """Backward-compatible convenience segmentation.

        Current flow is proposal-first; this picks top proposals automatically.
        """
        proposed = await self.propose_masks(query, frame_b64)
        try:
            payload = json.loads(proposed)
        except Exception:
            return proposed

        count = int(payload.get("count", 0))
        if count <= 0:
            return f"No objects detected for '{query}'."

        top_k = min(25, count)
        auto_indices = list(range(top_k))
        return self.apply_masks(auto_indices, query=query)

    def clear_masks(self) -> str:
        """Remove all active masks."""
        count = len(self.active_masks)
        self.active_masks.clear()
        self.latest_proposals = []
        self.color_idx = 0
        return f"Cleared {count} mask(s)."

    def render_frame(self, b64_frame: str) -> str:
        """Render the current frame with static mask overlays.
        
        This is called for every WebSocket frame.
        If no masks are active, returns the frame unchanged.
        """
        # Strip data-URI prefix
        raw = b64_frame.split(',', 1)[-1] if ',' in b64_frame else b64_frame
        self._latest_b64 = raw
        
        # Fast path: no overlays → passthrough (no decode/encode!)
        if not self.active_masks:
            return raw
        
        # Decode, overlay, encode
        img = self._decode(raw)
        if img is None:
            return raw

        h, w = img.shape[:2]

        # Ensure static rasters are present for fast per-frame rendering.
        for md in self.active_masks:
            raster = md.get("raster")
            if raster is None or raster.shape[:2] != (h, w):
                md["raster"] = self._contours_to_binary_mask(h, w, md.get("contours", []))
        
        # Draw all active masks with strong fill + clear boundaries
        fill_layer = np.zeros_like(img, dtype=np.uint8)
        
        for mask in self.active_masks:
            color = mask["color"]
            raster = mask.get("raster")
            if raster is None:
                continue
            fill_layer[raster > 0] = color

        cv2.addWeighted(fill_layer, 0.42, img, 0.58, 0, dst=img)

<<<<<<< Updated upstream
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
=======
        for mask in self.active_masks:
            contours = [self._sanitize_contour(c) for c in mask.get("contours", [])]
            contours = [c for c in contours if c is not None]
            if contours:
                cv2.drawContours(img, contours, -1, mask["color"], thickness=2)
        
        return self._encode(img)
>>>>>>> Stashed changes
