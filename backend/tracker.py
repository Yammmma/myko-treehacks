import base64
import asyncio
import json
import os
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

try:
    from cellpose import models as cellpose_models
    HAS_CELLPOSE = False
except Exception:
    cellpose_models = None
    HAS_CELLPOSE = False

try:
    import torch
    from sam2.build_sam import build_sam2
    from sam2.automatic_mask_generator import SAM2AutomaticMaskGenerator
    HAS_SAM2 = True
except Exception:
    torch = None
    build_sam2 = None
    SAM2AutomaticMaskGenerator = None
    HAS_SAM2 = False


class Segmenter:
    """Simple static segmentation - no tracking, just segment and render."""
    
    def __init__(self):
        self.active_masks = []        # List of {contours, color, query} dicts
        self.latest_proposals = []    # List of {contour, area, circularity, center, bbox, score}
        self._latest_b64 = None       # raw base64 (no data-uri prefix)
        self._original_dimensions = None  # (height, width) when proposals were made
        self._jpeg_quality = 75
        self._has_skimage = HAS_SKIMAGE
        self._has_cellpose = HAS_CELLPOSE
        self._has_sam2 = HAS_SAM2
        self._default_backend = os.getenv("SEGMENTATION_BACKEND", "auto").strip().lower()
        self._auto_fast_mode = os.getenv("SEGMENTATION_AUTO_FAST", "1").strip().lower() not in {"0", "false", "no"}

        self._cellpose_model = None
        self._sam2_mask_generator = None
        self._frame_counter = 0
        self._recalc_interval = 60
        
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
        
        print(
            "✅ Segmenter ready "
            f"(default={self._default_backend}, skimage={self._has_skimage}, "
            f"cellpose={self._has_cellpose}, sam2={self._has_sam2}, auto_fast={self._auto_fast_mode})"
        )

    def _resolve_backend(self, backend: str | None = None) -> str:
        selected = (backend or self._default_backend or "auto").strip().lower()
        if selected not in {"auto", "opencv", "cellpose", "sam2"}:
            selected = "auto"

        if selected == "auto":
            # Preserve auto so dispatcher can try cellpose/sam2/opencv in order.
            return "auto"

        if selected == "cellpose" and not self._has_cellpose:
            return "opencv"
        if selected == "sam2" and not self._has_sam2:
            return "opencv"
        return selected

    def _get_cellpose_model(self):
        if not self._has_cellpose:
            return None
        if self._cellpose_model is None:
            self._cellpose_model = cellpose_models.CellposeModel(gpu=torch.cuda.is_available())
        return self._cellpose_model

    def _get_sam2_generator(self):
        if not self._has_sam2:
            return None
        if self._sam2_mask_generator is not None:
            return self._sam2_mask_generator

        ckpt = os.getenv("SAM2_CHECKPOINT", "").strip()
        cfg = os.getenv("SAM2_MODEL_CFG", "sam2_hiera_t.yaml").strip()
        if not ckpt:
            return None

        device = "cuda" if torch is not None and torch.cuda.is_available() else "cpu"
        model = build_sam2(cfg, ckpt, device=device)
        self._sam2_mask_generator = SAM2AutomaticMaskGenerator(model)
        return self._sam2_mask_generator

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
    def _query_score(query: str, feat: dict, img_area: float = 1.0) -> float:
        """Score a candidate contour for relevance to *query*.

        All area thresholds are expressed as fractions of *img_area* so
        the scoring is resolution-independent.
        """
        q = (query or "").lower()
        score = 0.0
        area = feat["area"]
        circularity = feat["circularity"]
        w = max(feat["bbox"][2], 1)
        h = max(feat["bbox"][3], 1)
        aspect = max(w, h) / max(1.0, min(w, h))

        # Normalised area (fraction of image).  A typical microscopy
        # red blood cell is ~0.5 %–2 % of the field-of-view.
        rel_area = area / max(img_area, 1.0)

        # Base score: prefer reasonably sized, round objects
        score += min(1.0, rel_area / 0.0003)   # saturates at ~0.03 % of image
        score += circularity

        if "red blood" in q or "rbc" in q:
            score += 1.3 * circularity
            # RBC-sized sweet spot: 0.3 %–2.5 % of the image
            if 0.003 <= rel_area <= 0.025:
                score += 0.8
            # Penalise very tiny specks (< 0.005 % of image)
            if rel_area < 0.00005:
                score -= 0.6
            if aspect <= 1.5:
                score += 0.5
        elif "all" in q or "cell" in q:
            score += 0.3

        if "large" in q:
            score += min(1.2, rel_area / 0.002)
        if "small" in q:
            score += 0.9 if rel_area < 0.0003 else -0.3

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
        h, w = img.shape[:2]
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
        hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)

        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        gray_eq = clahe.apply(gray)
        gray_blur = cv2.GaussianBlur(gray_eq, (5, 5), 0)

        sigma = max(10.0, float(min(h, w)) * 0.06)
        bg = cv2.GaussianBlur(gray_eq, (0, 0), sigmaX=sigma, sigmaY=sigma)
        gray_norm = ((gray_eq.astype(np.float32) + 1.0) / (bg.astype(np.float32) + 1.0))
        gray_norm = cv2.normalize(gray_norm, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
        gray_norm_blur = cv2.GaussianBlur(gray_norm, (5, 5), 0)

        _, m_otsu = cv2.threshold(gray_blur, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        m_adapt = cv2.adaptiveThreshold(
            gray_blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv2.THRESH_BINARY_INV, 31, 4
        )
        _, m_otsu_norm = cv2.threshold(gray_norm_blur, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        m_adapt_norm = cv2.adaptiveThreshold(
            gray_norm_blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv2.THRESH_BINARY_INV, 31, 3
        )

        blackhat_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
        blackhat = cv2.morphologyEx(gray_norm_blur, cv2.MORPH_BLACKHAT, blackhat_kernel)
        bh_thr = int(np.percentile(blackhat[roi_mask > 0], 75)) if np.any(roi_mask > 0) else 20
        m_blackhat = (blackhat > max(12, bh_thr)).astype(np.uint8) * 255

        s = hsv[:, :, 1]
        s_thr = int(np.percentile(s[roi_mask > 0], 60)) if np.any(roi_mask > 0) else 40
        m_sat = (s > max(18, s_thr - 8)).astype(np.uint8) * 255

        a_u8 = lab[:, :, 1].astype(np.uint8)
        a = a_u8.astype(np.int16)
        b = lab[:, :, 2].astype(np.int16)
        med_a = int(np.median(a[roi_mask > 0])) if np.any(roi_mask > 0) else 128
        med_b = int(np.median(b[roi_mask > 0])) if np.any(roi_mask > 0) else 128
        stain_dev = np.abs(a - med_a) + np.abs(b - med_b)
        dev_thr = int(np.percentile(stain_dev[roi_mask > 0], 65)) if np.any(roi_mask > 0) else 30
        m_stain = (stain_dev > max(18, dev_thr)).astype(np.uint8) * 255

        a_thr = int(np.percentile(a_u8[roi_mask > 0], 62)) if np.any(roi_mask > 0) else 132
        m_red = (a_u8 > max(128, a_thr)).astype(np.uint8) * 255

        votes = (m_otsu > 0).astype(np.uint8)
        votes += (m_adapt > 0).astype(np.uint8)
        votes += (m_otsu_norm > 0).astype(np.uint8)
        votes += (m_adapt_norm > 0).astype(np.uint8)
        votes += (m_blackhat > 0).astype(np.uint8)
        votes += (m_sat > 0).astype(np.uint8)
        votes += (m_stain > 0).astype(np.uint8)
        votes += (m_red > 0).astype(np.uint8)
        combined = (votes >= 3).astype(np.uint8) * 255

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

    def _find_contours_cellpose(self, img: np.ndarray, query: str) -> list:
        model = self._get_cellpose_model()
        if model is None:
            return self._find_contours(img, query)

        h, w = img.shape[:2]
        region_mask = self._region_mask(query, h, w)
        bgr = img.copy()
        bgr[region_mask == 0] = 0

        # Cellpose expects RGB
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        out = model.eval(
            rgb,
            diameter=None,
            flow_threshold=0.4,
            cellprob_threshold=0.0,
            normalize=True,
        )
        if isinstance(out, tuple):
            masks = out[0]
        else:
            masks = out

        contours = []
        max_label = int(np.max(masks)) if masks is not None else 0
        min_area = max(12, int(h * w * 0.00001))
        max_area = int(h * w * 0.05)

        for label in range(1, max_label + 1):
            inst = (masks == label).astype(np.uint8)
            if not np.any(inst):
                continue
            area = int(np.sum(inst))
            if area < min_area or area > max_area:
                continue

            cnts, _ = cv2.findContours(inst * 255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            if not cnts:
                continue
            contour = max(cnts, key=cv2.contourArea)
            contour = self._sanitize_contour(contour)
            if contour is not None:
                contours.append(contour)

        print(f"  🧫 Cellpose found {len(contours)} contours")
        return contours

    def _find_contours_sam2(self, img: np.ndarray, query: str) -> list:
        generator = self._get_sam2_generator()
        if generator is None:
            return self._find_contours(img, query)

        h, w = img.shape[:2]
        region_mask = self._region_mask(query, h, w)
        rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

        masks = generator.generate(rgb)
        contours = []
        min_area = max(12, int(h * w * 0.00001))
        max_area = int(h * w * 0.05)

        for md in masks:
            seg = md.get("segmentation")
            if seg is None:
                continue
            seg_u8 = seg.astype(np.uint8)
            seg_u8[region_mask == 0] = 0
            area = int(np.sum(seg_u8 > 0))
            if area < min_area or area > max_area:
                continue

            cnts, _ = cv2.findContours(seg_u8 * 255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            if not cnts:
                continue
            contour = max(cnts, key=cv2.contourArea)
            contour = self._sanitize_contour(contour)
            if contour is not None:
                contours.append(contour)

        print(f"  🧠 SAM2 found {len(contours)} contours")
        return contours

    def _find_contours_dispatch(self, img: np.ndarray, query: str, backend: str | None = None) -> tuple[list, str]:
        mode = (backend or self._default_backend or "auto").strip().lower()
        if mode == "auto":
            # Always run fast OpenCV first for low latency.
            opencv_contours = self._find_contours(img, query)
            if self._auto_fast_mode:
                return opencv_contours, "opencv"

            # Optional slower refinement mode: only try heavier backends when
            # OpenCV confidence/recall appears low.
            best_contours = opencv_contours
            best_backend = "opencv"
            baseline = max(1, len(opencv_contours))

            plans = ["cellpose", "sam2"]
            for selected in plans:
                if selected == "cellpose" and not self._has_cellpose:
                    continue
                if selected == "sam2" and not self._has_sam2:
                    continue
                try:
                    if selected == "cellpose":
                        contours = self._find_contours_cellpose(img, query)
                    else:
                        contours = self._find_contours_sam2(img, query)

                    # Only switch if meaningfully better recall.
                    if len(contours) >= int(1.2 * baseline) and len(contours) > len(best_contours):
                        best_contours = contours
                        best_backend = selected
                except Exception as err:
                    print(f"⚠️ Backend '{selected}' failed in auto mode: {err}")

            return best_contours, best_backend

        selected = self._resolve_backend(mode)
        try:
            if selected == "cellpose":
                return self._find_contours_cellpose(img, query), selected
            if selected == "sam2":
                return self._find_contours_sam2(img, query), selected
            return self._find_contours(img, query), "opencv"
        except Exception as err:
            print(f"⚠️ Backend '{selected}' failed: {err} — falling back to opencv")
            return self._find_contours(img, query), "opencv"

    def _store_proposals(self, contours: list[np.ndarray], query: str, img_shape: tuple, limit: int = 400) -> list[dict]:
        img_area = float(img_shape[0]) * float(img_shape[1])  # h * w
        proposals = []
        for contour in contours:
            contour = self._sanitize_contour(contour)
            if contour is None:
                continue
            feat = self._contour_features(contour)
            score = self._query_score(query, feat, img_area=img_area)
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
        self._original_dimensions = img_shape[:2]  # Store (height, width)
        return self.latest_proposals

    async def propose_masks(self, query: str, frame_b64: str | None = None, backend: str | None = None) -> str:
        img = None
        source = None

        # Prefer the explicitly-provided frame (sent with the POST /query)
        # over _latest_b64, which races with the WS stream and may be a
        # completely different camera view by now.
        if frame_b64:
            raw = frame_b64.split(',', 1)[-1] if ',' in frame_b64 else frame_b64
            img = self._decode(raw)
            if img is not None:
                source = "frame_b64"
                # Pin this frame so render_frame uses the same reference
                self._latest_b64 = raw

        if img is None and self._latest_b64:
            img = self._decode(self._latest_b64)
            source = "_latest_b64"

        if img is None:
            return "No image available - send a frame over the WebSocket first."

        requested_backend = (backend or self._default_backend or "auto").strip().lower()
        selected_backend = self._resolve_backend(requested_backend)
        print(f"🔬 Proposing masks for: '{query}' (backend={selected_backend}, source={source}, img={img.shape[1]}x{img.shape[0]})")
        timeout_sec = {
            "opencv": 2.0,
            "cellpose": 8.0,
            "sam2": 10.0,
            "auto": 12.0,
        }.get(selected_backend, 6.0)

        try:
            contours, used_backend = await asyncio.wait_for(
                asyncio.to_thread(self._find_contours_dispatch, img, query, selected_backend),
                timeout=timeout_sec,
            )
        except TimeoutError:
            print(f"⚠️ Segmentation timeout on backend={selected_backend}; falling back to opencv")
            if selected_backend != "opencv":
                contours, used_backend = await asyncio.to_thread(
                    self._find_contours_dispatch,
                    img,
                    query,
                    "opencv",
                )
            else:
                contours, used_backend = [], "opencv"

        if not contours:
            self.latest_proposals = []
            self._original_dimensions = None
            return json.dumps({"count": 0, "backend": used_backend, "candidates": []})

        proposals = self._store_proposals(contours, query, img.shape)
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

        return json.dumps({"count": len(proposals), "backend": used_backend, "candidates": preview})

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

        max_selected = 220

        # If user asked for all/every, don't depend on tool-selected subset.
        q = (query or "").lower()
        if ("all" in q or "every" in q) and len(self.latest_proposals) > len(valid):
            valid = list(range(min(max_selected, len(self.latest_proposals))))

        wants_specific = any(token in q for token in ["single", "one", "top", "best", "largest", "smallest"]) 
        if not wants_specific and self.latest_proposals:
            scores = [float(p.get("score", 0.0)) for p in self.latest_proposals]
            peak = max(scores) if scores else 0.0
            # Include all proposals with "reasonable" confidence relative to peak.
            conf_floor = peak * 0.72
            conf_indices = [i for i, p in enumerate(self.latest_proposals) if float(p.get("score", 0.0)) >= conf_floor]
            if len(conf_indices) > len(valid):
                valid = sorted(set(valid).union(conf_indices))

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

        # Store original contours + the dimensions they were computed at.
        # render_frame will scale from these originals for any output size.
        orig_dims = self._original_dimensions  # (h, w) from propose_masks
        normalized = self._normalize_contours(selected, orig_dims)
        print(f"📐 apply_masks: original_dimensions={orig_dims}, contours={len(selected)}")
        self.active_masks.append({
            "original_contours": selected,       # never modified
            "normalized_contours": normalized,   # preferred scaling representation
            "original_dimensions": orig_dims,    # (h, w) they were found at
            "contours": None,                    # scaled copy – computed lazily
            "raster": None,                      # binary mask  – computed lazily
            "scaled_for": None,                  # (h, w) the cache is valid for
            "color": color,
            "query": query,
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
        self._original_dimensions = None
        self.color_idx = 0
        return f"Cleared {count} mask(s)."

    # ------------------------------------------------------------------
    # Scaling helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _normalize_contours(contours: list[np.ndarray], dims: tuple[int, int] | None) -> list[np.ndarray] | None:
        """Convert contours to [0,1] coordinates so scaling is resolution-independent."""
        if not dims:
            return None
        h, w = dims
        if h <= 0 or w <= 0:
            return None

        normalized = []
        for contour in contours:
            if contour is None:
                continue
            c = np.asarray(contour).copy().astype(np.float64)
            if c.ndim != 3 or c.shape[2] != 2:
                continue
            c[:, :, 0] = np.clip(c[:, :, 0] / float(w), 0.0, 1.0)
            c[:, :, 1] = np.clip(c[:, :, 1] / float(h), 0.0, 1.0)
            normalized.append(c)
        return normalized

    @staticmethod
    def _contours_from_normalized(norm_contours: list[np.ndarray], h: int, w: int) -> list[np.ndarray]:
        """Project normalized contours to integer pixel coordinates for a target frame."""
        if h <= 0 or w <= 0:
            return []

        projected = []
        for contour in norm_contours:
            if contour is None:
                continue
            c = np.asarray(contour).copy().astype(np.float64)
            if c.ndim != 3 or c.shape[2] != 2:
                continue
            c[:, :, 0] = np.clip(np.rint(c[:, :, 0] * float(w)), 0, max(0, w - 1))
            c[:, :, 1] = np.clip(np.rint(c[:, :, 1] * float(h)), 0, max(0, h - 1))
            projected.append(c.astype(np.int32))
        return projected

    @staticmethod
    def _scale_contours(
        contours: list[np.ndarray],
        orig_h: int, orig_w: int,
        dst_h: int, dst_w: int,
    ) -> list[np.ndarray]:
        """Scale a list of contours from (orig_h, orig_w) to (dst_h, dst_w)."""
        if orig_h == dst_h and orig_w == dst_w:
            return [c.copy() for c in contours if c is not None]

        scale_x = dst_w / max(orig_w, 1)
        scale_y = dst_h / max(orig_h, 1)

        scaled = []
        for contour in contours:
            if contour is None:
                continue
            c = contour.copy().astype(np.float64)
            c[:, :, 0] *= scale_x   # x
            c[:, :, 1] *= scale_y   # y
            scaled.append(c.astype(np.int32))
        return scaled

    def _ensure_scaled(self, md: dict, h: int, w: int) -> None:
        """Lazily (re-)compute scaled contours + raster for a mask dict.

        Always scales from *original_contours* so errors never accumulate.
        """
        if md.get("scaled_for") == (h, w) and md.get("raster") is not None:
            return  # cache hit

        norm_contours = md.get("normalized_contours")
        orig_contours = md.get("original_contours", [])
        orig_dims = md.get("original_dimensions")  # (orig_h, orig_w)

        if norm_contours:
            scaled = self._contours_from_normalized(norm_contours, h, w)
        elif orig_dims is not None:
            orig_h, orig_w = orig_dims
            scaled = self._scale_contours(orig_contours, orig_h, orig_w, h, w)
        else:
            # Fallback: assume contours are already at current resolution
            scaled = [c.copy() for c in orig_contours if c is not None]

        md["contours"] = scaled
        md["raster"] = self._contours_to_binary_mask(h, w, scaled)
        md["scaled_for"] = (h, w)

    def _recalc_masks(self, img: np.ndarray) -> None:
        """Re-run segmentation on the current frame to reposition active masks."""
        if not self.active_masks:
            return
        h, w = img.shape[:2]
        for md in self.active_masks:
            query = md.get("query", "all cells")
            backend = "opencv"  # fast path for real-time recalc
            try:
                contours, used = self._find_contours_dispatch(img, query, backend)
            except Exception as e:
                print(f"⚠️ recalc_masks error: {e}")
                continue
            if not contours:
                continue
            # Re-score and pick top matches
            img_area = float(h * w)
            scored = []
            for c in contours:
                c = self._sanitize_contour(c)
                if c is None:
                    continue
                feat = self._contour_features(c)
                score = self._query_score(query, feat, img_area=img_area)
                scored.append((c, score))
            scored.sort(key=lambda x: x[1], reverse=True)
            peak = scored[0][1] if scored else 0.0
            conf_floor = peak * 0.72
            selected = [c for c, s in scored if s >= conf_floor][:220]
            if not selected:
                continue
            normalized = self._normalize_contours(selected, (h, w))
            md["original_contours"] = selected
            md["normalized_contours"] = normalized
            md["original_dimensions"] = (h, w)
            md["contours"] = None
            md["raster"] = None
            md["scaled_for"] = None
        print(f"🔄 Recalculated masks at frame {self._frame_counter}")

    def render_frame(self, b64_frame: str) -> str:
        """Render the current frame with static mask overlays.
        
        This is called for every WebSocket frame.
        If no masks are active, returns the frame unchanged.
        """
        # Strip data-URI prefix
        raw = b64_frame.split(',', 1)[-1] if ',' in b64_frame else b64_frame
        self._latest_b64 = raw
        self._frame_counter += 1
        
        # Fast path: no overlays → passthrough (no decode/encode!)
        if not self.active_masks:
            return raw
        
        # Decode, overlay, encode
        img = self._decode(raw)
        if img is None:
            return raw

        h, w = img.shape[:2]

        # Recalculate masks every k frames to handle camera shifts
        if self._frame_counter % self._recalc_interval == 0:
            self._recalc_masks(img)

        # Ensure scaled contours + rasters match current frame dimensions.
        for md in self.active_masks:
            orig = md.get("original_dimensions")
            if orig and orig != (h, w):
                print(f"⚠️ render_frame: frame={w}x{h} vs segmentation={orig[1]}x{orig[0]} — scaling")
            self._ensure_scaled(md, h, w)
        
        # Draw all active masks with strong fill + clear boundaries
        fill_layer = np.zeros_like(img, dtype=np.uint8)
        
        for mask in self.active_masks:
            color = mask["color"]
            raster = mask.get("raster")
            if raster is None:
                continue
            fill_layer[raster > 0] = color

        cv2.addWeighted(fill_layer, 0.55, img, 0.45, 0, dst=img)

        for mask in self.active_masks:
            contours = [self._sanitize_contour(c) for c in mask.get("contours", [])]
            contours = [c for c in contours if c is not None]
            if contours:
                thickness = max(2, int(round(min(h, w) * 0.003)))
                cv2.drawContours(img, contours, -1, mask["color"], thickness=thickness)
        
        return self._encode(img)
