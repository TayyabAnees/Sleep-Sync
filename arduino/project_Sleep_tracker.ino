#include <Wire.h>
#include <MPU6050.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <WiFiClientSecure.h>

//WIFI Credentials
#define WIFI_SSID "Winter-net"
#define WIFI_PASSWORD "WINTERNET0311646398"

const char *mqtt_broker = "broker";
const char *mqtt_username = "username";
const char *mqtt_password = "password";
const int mqtt_port = 8883;

bool sleepTrackingEnabled = false;
bool wakeUpSignal = false;

WiFiClientSecure esp_client;
PubSubClient mqtt_client(esp_client);

// MPU6050 setup
MPU6050 accelgyro;
int16_t ax, ay, az;
int16_t gx, gy, gz;

// Root certificate
const char *ca_cert = "YOUR CERT";

void connectToWiFi() {
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
    Serial.print("Connecting to WiFi");
    while (WiFi.status() != WL_CONNECTED) {
        delay(500);
        Serial.print(".");
    }
    Serial.println("\nConnected to WiFi");
}

void connectToMQTT() {
    while (!mqtt_client.connected()) {
        String client_id = "esp32-client-" + String(WiFi.macAddress());
        Serial.printf("Connecting to MQTT as %s...\n", client_id.c_str());
        if (mqtt_client.connect(client_id.c_str(), mqtt_username, mqtt_password)) {
            Serial.println("Connected to MQTT");
        } else {
            Serial.print("MQTT connect failed, rc=");
            Serial.print(mqtt_client.state());
            Serial.println(" Retrying in 5 seconds");
            delay(5000);
        }
    }
}
void callback(char* topic, byte* payload, unsigned int length) {
    String topicStr = String(topic);
    String payloadStr;

    for (unsigned int i = 0; i < length; i++) {
        payloadStr += (char)payload[i];
    }

    if (topicStr == "sleeptrackON/") {
        sleepTrackingEnabled = (payloadStr == "1");
    } else if (topicStr == "wakeUp/") {
        wakeUpSignal = (payloadStr == "1");
    }
}

void setup() {
    pinMode(21, OUTPUT);  
    Serial.begin(115200);
    connectToWiFi();
    esp_client.setCACert(ca_cert);
    mqtt_client.setServer(mqtt_broker, mqtt_port);
    connectToMQTT();
     Wire.begin(19,18);
    accelgyro.initialize();
    mqtt_client.setCallback(callback);
    mqtt_client.subscribe("sleeptrackON/");
    mqtt_client.subscribe("wakeUp/");
    if (!accelgyro.testConnection()) {
        Serial.println("MPU6050 connection failed!");
        while (1);
    }

}

void loop() {
  if (!mqtt_client.connected()) {
        connectToMQTT();
        mqtt_client.subscribe("sleeptrackON/");
        mqtt_client.subscribe("wakeUp/");
    }
    mqtt_client.loop();

    // Handle wakeUp signal
    digitalWrite(21, wakeUpSignal ? HIGH : LOW);

    // If sleep tracking is enabled, send accelerometer data
    if (sleepTrackingEnabled) {
      accelgyro.getAcceleration(&ax, &ay, &az);

        // Normalize to 2–-2 range
       float gx = ax * (2.0 / 32768.0);
      float gy = ay * (2.0 / 32768.0);
       float gz = az * (2.0 / 32768.0);

        // Prepare JSON with float values
        char json_msg[128];
       snprintf(json_msg, sizeof(json_msg), "{\"x\":%.2f,\"y\":%.2f,\"z\":%.2f}", gx, gy, gz);

       mqtt_client.publish("acc/data", json_msg);
      Serial.println(json_msg);
      delay(1000);
    }

    delay(1000);  // 1s delay between loops
}
