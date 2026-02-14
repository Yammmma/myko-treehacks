import sys
import os
import numpy as np
from PIL import Image, ImageDraw

# Ensure we can import from the current directory
sys.path.append(os.getcwd())

def create_dummy_frame(x, y, size=100, width=1024, height=1024):
    """
    Creates a black image with a white square at (x, y).
    """
    img = Image.new('RGB', (width, height), color='black')
    draw = ImageDraw.Draw(img)
    draw.rectangle([x, y, x + size, y + size], fill='white')
    return img

def test_wrapper():
    print("🚀 Starting SAM 2 Wrapper Test...\n")

    # 1. Import Verification
    try:
        from sam2_wrapper import SAM2Wrapper
        print("✅ [1/5] Import successful.")
    except ImportError as e:
        print(f"❌ [1/5] Import Failed: {e}")
        print("   -> Make sure you are in the root directory containing sam2_wrapper.py")
        sys.exit(1)

    # 2. Initialization
    try:
        print("⏳ [2/5] Initializing SAM2Wrapper (Loading Hiera Large)...")
        sam = SAM2Wrapper()
        print(f"✅ [2/5] Model loaded on device: {sam.device}")
    except Exception as e:
        print(f"❌ [2/5] Model Load Failed: {e}")
        print("   -> Check if checkpoints/sam2_hiera_large.pt exists.")
        sys.exit(1)

    # 3. Test Agnostic Mask Generation (Auto-Mask)
    print("\n⏳ [3/5] Testing get_agnostic_masks()...")
    frame1 = create_dummy_frame(50, 50) # Object at top-left
    
    try:
        masks = sam.get_agnostic_masks(frame1)
        
        if isinstance(masks, list) and len(masks) > 0:
            first_mask = masks[0]
            required_keys = ['segmentation', 'bbox', 'area']
            if all(k in first_mask for k in required_keys):
                print(f"✅ [3/5] Success! Found {len(masks)} masks.")
                print(f"   -> Sample Mask Area: {first_mask['area']}")
                print(f"   -> Sample BBox: {first_mask['bbox']}")
            else:
                print(f"❌ [3/5] Invalid mask format. Missing keys. Got: {first_mask.keys()}")
        else:
            print("❌ [3/5] No masks found (Unexpected for clear white square).")
    except Exception as e:
        print(f"❌ [3/5] Execution Error: {e}")

    # 4. Test Single Point Prediction (Initialization)
    print("\n⏳ [4/5] Testing predict_next_frame() (Point Initialization)...")
    
    # Simulate user clicking the center of the square (approx 100, 100)
    # create_dummy_frame makes a 100x100 square at 50,50 -> center is 100,100
    input_point = np.array([[100, 100]], dtype=np.float32)
    input_label = np.array([1], dtype=np.int32)
    
    frame1_np = np.array(frame1)
    
    try:
        # We pass None for previous_mask to simulate first interaction
        mask_result, logit_result = sam.predict_next_frame(
            frame1_np, 
            previous_mask=None, 
            point_coords=input_point, 
            point_labels=input_label
        )
        
        # Verify Output
        if mask_result is not None and logit_result is not None:
            print(f"✅ [4/5] Success! Prediction returned.")
            print(f"   -> Mask Shape: {mask_result.shape} (Should be HxW)")
            print(f"   -> Logits Shape: {logit_result.shape} (Should be 1x256x256)")
            
            # Save for next step
            saved_logits = logit_result
        else:
            print("❌ [4/5] Prediction returned None/None.")
            sys.exit(1)

    except Exception as e:
        print(f"❌ [4/5] Execution Error: {e}")
        sys.exit(1)

    # 5. Test Mask Propagation (Tracking)
    print("\n⏳ [5/5] Testing predict_next_frame() (Propagation)...")
    
    # Move object slightly
    frame2 = create_dummy_frame(60, 60) 
    frame2_np = np.array(frame2)
    
    try:
        # Pass the LOGITS from step 4 into step 5
        mask_result_2, logit_result_2 = sam.predict_next_frame(
            frame2_np, 
            previous_mask=saved_logits, # <--- The key tracking mechanism
            point_coords=None, 
            point_labels=None
        )

        if mask_result_2 is not None:
             # Check if the mask actually found something (sum > 0)
            mask_pixels = np.sum(mask_result_2 > 0)
            if mask_pixels > 0:
                print(f"✅ [5/5] Success! Object tracked to new frame.")
                print(f"   -> New Mask Pixels: {mask_pixels}")
            else:
                print("⚠️ [5/5] Warning: Mask is empty (Tracking might have been lost).")
        else:
            print("❌ [5/5] Propagation failed (Returned None).")

    except Exception as e:
        print(f"❌ [5/5] Execution Error: {e}")

    print("\n🏁 Test Complete.")

if __name__ == "__main__":
    test_wrapper()