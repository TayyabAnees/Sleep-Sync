import os
from flask import Flask, request, jsonify
import paho.mqtt.client as mqtt_client
from paho.mqtt.client import CallbackAPIVersion
import threading
import json
import pandas as pd
import numpy as np
import joblib
from datetime import datetime, timedelta
from sklearn.preprocessing import MinMaxScaler
import logging
import time
import ssl

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Flask app
app = Flask(__name__)

# MQTT configuration
BROKER = ''
PORT = 8883
CLIENT_ID = f'python-mqtt-{np.random.randint(0, 1000)}'
USERNAME = ''
PASSWORD = ''

# Global variables
alarm_window = None  # Stores (start_time, end_time)
data_buffer = []  # Stores accelerometer data
is_tracking = False  # Tracks if sleep tracking is active
model = None
scaler = None
feature_columns = None
sleep_windows_file = 'sleep_windows.csv'


# Load model, scaler, and feature columns
def load_artifacts():
    global model, scaler, feature_columns
    try:
        model = joblib.load('sleep_state_model.pkl')
        scaler = joblib.load('scaler.pkl')
        feature_columns = joblib.load('feature_columns.pkl')
        logging.info("Model, scaler, and feature columns loaded successfully.")
    except FileNotFoundError as e:
        logging.error(f"Error loading artifacts: {e}. Ensure .pkl files are present.")
        raise


# Function to extract features from a 30-minute window
def extract_features(window):
    features = {}
    for axis in ['ax', 'ay', 'az']:
        features[f'{axis}_mean'] = window[axis].mean()
        features[f'{axis}_std'] = window[axis].std()
        features[f'{axis}_min'] = window[axis].min()
        features[f'{axis}_max'] = window[axis].max()
        features[f'{axis}_median'] = window[axis].median()
        features[f'{axis}_range'] = window[axis].max() - window[axis].min()
    magnitude = np.sqrt(window['ax'] ** 2 + window['ay'] ** 2 + window['az'] ** 2)
    features['magnitude_mean'] = magnitude.mean()
    features['magnitude_std'] = magnitude.std()
    return pd.Series(features)


# Function to predict sleep state for a 30-minute DataFrame
def predict_sleep_state(new_data):
    if len(new_data) != 30:
        raise ValueError("Input DataFrame must contain exactly 30 rows (30 minutes).")
    if not all(col in new_data.columns for col in ['ax', 'ay', 'az']):
        raise ValueError("Input DataFrame must contain 'ax', 'ay', 'az' columns.")

    new_data_normalized = new_data.copy()
    new_data_normalized[['ax', 'ay', 'az']] = scaler.transform(new_data[['ax', 'ay', 'az']])

    features = extract_features(new_data_normalized)
    features_df = pd.DataFrame([features], columns=feature_columns)

    prediction = model.predict(features_df)[0]
    probabilities = model.predict_proba(features_df)[0]
    prob_dict = dict(zip(model.classes_, probabilities))

    return prediction, prob_dict


# Save 30-minute window to CSV
def save_sleep_window(window_data, prediction, start_time, end_time):
    window_df = window_data.copy()
    window_df['timestamp'] = pd.date_range(start=start_time, end=end_time - timedelta(minutes=1), freq='min')
    window_df['sleep_state'] = prediction
    window_df['window_start'] = start_time
    window_df['window_end'] = end_time

    # Append to CSV
    header = not pd.io.common.file_exists(sleep_windows_file)
    window_df.to_csv(sleep_windows_file, mode='a', header=header, index=False)
    logging.info(f"Saved window {start_time} to {end_time} with state {prediction}")


# MQTT callbacks
def on_connect(client, userdata, flags, rc, *args):
    if rc == 0:
        logging.info("Connected to MQTT broker")
        client.subscribe("setalarm/#")
        client.subscribe("acc/data")
        client.subscribe("wakeUp/")
        client.subscribe("sleeptrackON/")
    else:
        logging.error(f"Failed to connect with code {rc}")


# Read, jsonify, and publish CSV data, then empty the file
# ax:0.52,ay:0.51,az:0.96,timestamp:2025-05-08 22:04:20.662332,sleep_state:Deep Sleep,window_start:2025-05-08 22:04:20.662332,window_end:2025-05-08 22:34:20.662332
def publish_and_clear_csv(client):
    try:
        if os.path.exists(sleep_windows_file):
            df = pd.read_csv(sleep_windows_file)
            custom_keys = ['ax', 'ay', 'az', 'timestamp', 'sleep_state', 'window_start', 'window_end']
            df.columns = custom_keys
            json_data = df.to_json(orient='records', lines=False)
            logging.info(f"Publishing JSON data to sleepdata/: {json_data}")
            client.publish("sleepdata/", json_data, retain=True)
            # Empty the CSV file
            open(sleep_windows_file, 'w').close()
            logging.info(f"Emptied {sleep_windows_file}")
        else:
            logging.warning(f"{sleep_windows_file} does not exist")
    except Exception as e:
        logging.error(f"Error processing {sleep_windows_file}: {e}")


def on_message(client, userdata, msg):
    global alarm_window, data_buffer, is_tracking

    topic = msg.topic
    payload = msg.payload.decode()
    logging.info(f"Received message on {topic}: {payload}")

    if topic.startswith("setalarm/"):
        # Parse alarm window: setalarm/YYYY-MM-DD,HH:MM-YYYY-MM-DD_HH:MM
        try:
            start_str, end_str = payload.split(',')
            start_time = datetime.strptime(start_str, '%Y-%m-%d_%H:%M')
            end_time = datetime.strptime(end_str, '%Y-%m-%d_%H:%M')
            logging.info(f"Set alarm window")
            alarm_window = (start_time, end_time)
            logging.info(f"Set alarm window: {start_time} to {end_time}")
            client.publish("sleeptrackON/", "1")
        except ValueError as e:
            logging.error(f"Invalid alarm format: {payload}, error: {e}")

    elif topic == "acc/data" and is_tracking:
        # Parse accelerometer data: {"x":ax,"y":ay,"z":az}
        try:
            prediction = "null"
            data = json.loads(payload)
            data_buffer.append({
                'ax': float(data['x']),
                'ay': float(data['y']),
                'az': float(data['z'])
            })

            # Process 30-minute window
            if len(data_buffer) >= 30:
                window_data = pd.DataFrame(data_buffer[-30:])
                start_time = datetime.now() - timedelta(minutes=30)
                end_time = datetime.now()

                # Predict sleep state
                prediction, probabilities = predict_sleep_state(window_data)
                logging.info(f"Predicted sleep state for {start_time} to {end_time}: {prediction}")
                logging.info(f"Probabilities: {probabilities}")

                # Save window
                save_sleep_window(window_data, prediction, start_time, end_time)
                # Clear buffer to start new window
                data_buffer = []  # Keep last 29 for overlap if needed
                # Check for wake-up condition
            if alarm_window[0] <= datetime.now() <= alarm_window[1]:
                if prediction == "Light Sleep":
                    logging.info("Light Sleep detected in alarm window, triggering wake-up")
                    client.publish("wakeUp/", "1")
                    client.publish("sleeptrackON/", "0")
                    is_tracking = False
                    alarm_window = None
                    data_buffer = []
                    publish_and_clear_csv(client)
            if alarm_window[1] <= datetime.now():
                logging.info("Alarm window Reached, triggering wake-up")
                client.publish("wakeUp/", "1")
                client.publish("sleeptrackON/", "0")
                is_tracking = False
                alarm_window = None
                data_buffer = []
                publish_and_clear_csv(client)
        except (json.JSONDecodeError, KeyError, ValueError) as e:
            logging.error(f"Error processing acc/data: {payload}, error: {e}")

    elif topic == "sleeptrackON/":
        is_tracking = (payload == "1")
        if not is_tracking:
            data_buffer = []
            logging.info("Sleep tracking stopped")


# Check if alarm start time is reached
def check_alarm(client):
    global alarm_window, is_tracking, data_buffer
    client.username_pw_set(USERNAME, PASSWORD)
    client.tls_set(tls_version=ssl.PROTOCOL_TLS)
    max_retries = 5
    retry_delay = 5
    for attempt in range(max_retries):
        try:
            client.connect(BROKER, PORT)
            logging.info(f"Alarm client connected to MQTT broker on attempt {attempt + 1}")
            break
        except Exception as e:
            logging.error(f"Alarm client failed to connect on attempt {attempt + 1}: {e}")
            if attempt < max_retries - 1:
                logging.info(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
            else:
                logging.error("Max retries reached for alarm client.")
                raise
    while True:
        if alarm_window and not is_tracking:
            now = datetime.now()
            start_time, end_time = alarm_window
            if start_time <= now:
                logging.info("Alarm start time reached, starting sleep tracking")
                client.publish("sleeptrackON/", "1")
                is_tracking = True
            if now > end_time:
                logging.info("Alarm window ended, stopping tracking")
                client.publish("sleeptrackON/", "0")

                is_tracking = False
                alarm_window = None
                data_buffer = []
        threading.Event().wait(10)  # Check every 10 seconds


# MQTT client setup
def mqtt_thread():
    client = mqtt_client.Client(client_id=CLIENT_ID, callback_api_version=mqtt_client.CallbackAPIVersion.VERSION2)
    client.username_pw_set(USERNAME, PASSWORD)
    client.tls_set(ca_certs='./server-ca.crt')
    client.on_connect = on_connect
    client.on_message = on_message
    max_retries = 5
    retry_delay = 5
    for attempt in range(max_retries):
        try:
            client.connect(BROKER, PORT)
            logging.info(f"Connected to MQTT broker on attempt {attempt + 1}")
            client.loop_forever()
            break
        except Exception as e:
            logging.error(f"Failed to connect to broker on attempt {attempt + 1}: {e}")
            if attempt < max_retries - 1:
                logging.info(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
            else:
                logging.error("Max retries reached. Could not connect to MQTT broker.")
                raise


# Flask routes
@app.route('/set_alarm', methods=['POST'])
def set_alarm():
    data = request.get_json()
    try:
        start_time = data['start_time']  # e.g., "2025-05-02_08:00"
        end_time = data['end_time']  # e.g., "2025-05-02_08:30"
        payload = f"{start_time}-{end_time}"
        client = mqtt_client.Client(client_id=f"flask-{np.random.randint(0, 1000)}",
                                    callback_api_version=mqtt_client.CallbackAPIVersion.VERSION1)
        client.username_pw_set(USERNAME, PASSWORD)
        client.tls_set(tls_version=ssl.PROTOCOL_TLS)
        max_retries = 5
        retry_delay = 5
        for attempt in range(max_retries):
            try:
                client.connect(BROKER, PORT)
                logging.info(f"Set alarm client connected on attempt {attempt + 1}")
                break
            except Exception as e:
                logging.error(f"Set alarm client failed to connect on attempt {attempt + 1}: {e}")
                if attempt < max_retries - 1:
                    logging.info(f"Retrying in {retry_delay} seconds...")
                    time.sleep(retry_delay)
                else:
                    logging.error("Max retries reached for set alarm client.")
                    raise
        client.publish(f"setalarm/{start_time}-{end_time}", payload)
        client.disconnect()
        return jsonify({"status": "success", "message": f"Alarm set for {start_time} to {end_time}"})
    except KeyError as e:
        return jsonify({"status": "error", "message": f"Missing field: {e}"}), 400
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


# Main function
def main():
    # Load model and scaler
    load_artifacts()

    # Start MQTT client in a separate thread
    mqtt_t = threading.Thread(target=mqtt_thread, daemon=True)
    mqtt_t.start()

    # Start alarm checker thread
    alarm_t = threading.Thread(target=check_alarm, args=(
        mqtt_client.Client(client_id=f"alarm-{np.random.randint(0, 1000)}",
                           callback_api_version=mqtt_client.CallbackAPIVersion.VERSION2),), daemon=True)
    alarm_t.start()

    # Start Flask server
    app.run(host='0.0.0.0', port=5000, debug=False)


if __name__ == "__main__":
    main()
