import torch
import numpy as np
from PIL import Image
from sam2.build_sam import build_sam2
from sam2.sam2_image_predictor import SAM2ImagePredictor
from sam2.automatic_mask_generator import SAM2AutomaticMaskGenerator

class SAM2Wrapper:
    def __init__(self):
        # 1. Device Setup (Mac Metal Performance Shaders)
        if torch.backends.mps.is_available():
            self.device = "mps"
            print("🍎 Using Apple Metal (MPS)")
        elif torch.cuda.is_available():
            self.device = "cuda"
            print("Dj Using CUDA")
        else:
            self.device = "cpu"
            print("⚠️ Using CPU (Slow)")

        # 2. Load Model (Hiera Large)
        checkpoint_path = "./checkpoints/sam2_hiera_large.pt"
        model_cfg = "sam2_hiera_l.yaml" # Config name matches the checkpoint size

        self.sam2_model = build_sam2(model_cfg, checkpoint_path, device=self.device)
        
        # 3. Initialize Tools
        self.mask_generator = SAM2AutomaticMaskGenerator(self.sam2_model)
        self.predictor = SAM2ImagePredictor(self.sam2_model)
        
        print("✅ SAM 2 Models Loaded")

    def get_agnostic_masks(self, frame_pil: Image.Image):
        """
        Generate all masks for the frame to let the Agent pick one.
        """
        frame_np = np.array(frame_pil)
        masks = self.mask_generator.generate(frame_np)
        return masks

    def predict_next_frame(self, frame_np, previous_mask=None, point_coords=None, point_labels=None):
        """
        Full predict: set_image + predict.  Used when only a single target is being tracked
        or when called outside the batch loop.
        """
        self.predictor.set_image(frame_np)
        return self.predict_only(previous_mask, point_coords, point_labels)

    def predict_only(self, previous_mask=None, point_coords=None, point_labels=None):
        """
        Predict mask WITHOUT calling set_image.
        Assumes predictor.set_image() was already called for this frame.
        This avoids running the expensive image encoder once per target.
        """
        if previous_mask is not None:
            masks, scores, logits = self.predictor.predict(
                mask_input=previous_mask,
                multimask_output=False
            )
        elif point_coords is not None:
            masks, scores, logits = self.predictor.predict(
                point_coords=point_coords,
                point_labels=point_labels,
                multimask_output=False
            )
        else:
            return None, None

        best_idx = np.argmax(scores)
        return masks[best_idx], logits[best_idx][None, :, :]