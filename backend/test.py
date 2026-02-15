import streamlit as st
import cv2
import numpy as np
import base64
import json
import requests
from websocket import create_connection

# --- CONFIG ---
SERVER_URL = "http://localhost:8000"
WS_URL = "ws://localhost:8000/ws"
IMG_PATH = "test_img.jpeg"

st.set_page_config(page_title="Myko Scope", layout="wide")

# Initialize chat history
if "messages" not in st.session_state:
    st.session_state.messages = []

# --- LAYOUT ---
col_video, col_chat = st.columns([2, 1])

with col_chat:
    st.header("💬 Agent Chat")
    
    # Display chat messages from history on app rerun
    for message in st.session_state.messages:
        with st.chat_message(message["role"]):
            st.markdown(message["content"])

    # React to user input
    if prompt := st.chat_input("Ask the microscope (e.g. 'find cells')..."):
        # Display user message in chat message container
        st.chat_message("user").markdown(prompt)
        # Add user message to chat history
        st.session_state.messages.append({"role": "user", "content": prompt})

        # Send to Backend
        try:
            res = requests.post(f"{SERVER_URL}/query", json={"prompt": prompt})
            if res.status_code == 200:
                response_text = res.json().get('response')
                # Display assistant response in chat message container
                with st.chat_message("assistant"):
                    st.markdown(response_text)
                # Add assistant response to chat history
                st.session_state.messages.append({"role": "assistant", "content": response_text})
            else:
                st.error("Server Error")
        except Exception as e:
            st.error(f"Connection Failed: {e}")

with col_video:
    st.header("🔬 Live Stream")
    image_placeholder = st.empty()

    # Load image once
    img = cv2.imread(IMG_PATH)
    if img is None:
        st.error("Image not found.")
        st.stop()

    # WebSocket Logic (Runs continuously)
    try:
        ws = create_connection(WS_URL)
        _, buffer = cv2.imencode('.jpg', img)
        b64_frame = base64.b64encode(buffer).decode('utf-8')

        # We use a loop that updates the image placeholder
        # Note: Streamlit re-runs the whole script on interaction. 
        # This loop blocks the script, so interactions (like chat) usually interrupt it 
        # and cause a re-run. This is standard "hacky" behavior for Streamlit video.
        while True:
            ws.send(json.dumps({"frame": b64_frame}))
            result = ws.recv()
            
            # Decode & Show
            img_data = base64.b64decode(result)
            np_arr = np.frombuffer(img_data, np.uint8)
            processed_img = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
            processed_img = cv2.cvtColor(processed_img, cv2.COLOR_BGR2RGB)
            
            # Use 'width' instead of 'use_container_width'
            image_placeholder.image(processed_img, channels="RGB", width="stretch")
            
    except Exception as e:
        # If the loop breaks (e.g. on chat input), it just restarts on the next rerun
        pass