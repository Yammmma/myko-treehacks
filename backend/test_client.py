import requests
import base64

# 1. Load an image and convert to Base64
# (Replace 'test.jpg' with a real image path on your machine)
IMAGE_PATH = "test.jpg" 

try:
    with open(IMAGE_PATH, "rb") as img_file:
        b64_string = base64.b64encode(img_file.read()).decode('utf-8')
except FileNotFoundError:
    print(f"⚠️  Please create a dummy image named '{IMAGE_PATH}' to test.")
    exit()

# 2. Send the Request
url = "http://localhost:8000/query"
payload = {
    "prompt": "What is in this image?",
    "frame": b64_string
}

print(f"Sending request to {url}...")
response = requests.post(url, json=payload)

# 3. Print Result
if response.status_code == 200:
    print("✅ Response:", response.json())
else:
    print(f"❌ Error {response.status_code}: {response.text}")