#pragma once
// ---------------------------------------------------------------------------
// Ble.h - the link to the phone app (prostart/). The board stays the only
// judge: the app mirrors what the display shows and, for the photofinish,
// learns the "go" instant on its own clock. Nothing the app sends can change
// a start.
//
// GATT. The app must not be able to tell which start unit it talks to. All
// integers little-endian. Advertised as "ProStart" with the service UUID.
//
//   service  F7280000-22EB-44D8-BE12-ECD2B6BDD709
//
//   event    F7280001-...  read + notify, 2-20 bytes
//            [0] u8  type          see BleEvent
//            [1] u8  counter       +1 per event: a gap means one was missed
//            then, by type:
//            COUNTDOWN  [2] u8 digit (3, 2, 1)
//            MARKS/SET/GO  [2..5] u32 t_us   the beep, board micros()
//            RESULT     [2] u8 verdict (BleVerdict)
//                       [3..6] i32 reaction time, us (negative: moved before go)
//                       [7..10] u32 onset t_us
//                       [11..14] u32 go t_us
//            The value stays readable, so an app connecting mid-start reads
//            where the board is instead of waiting for the next event.
//
//   ping     F7280002-...  write without response
//            app writes [0..1] u16 seq
//   pong     F7280003-...  notify
//            board replies [0..1] u16 seq  [2..5] u32 t_rx_us  [6..9] u32 t_tx_us
//            Two characteristics, not one: ArduinoBLE (XIAO) notified a written
//            value back to its subscribers, so a single write+notify one echoed
//            every ping as a 2-byte notification.
//            t_rx_us is when the write was handled, t_tx_us just before the
//            reply is queued, both board micros(). The app stamps its own
//            send (t1) and receive (t4) and keeps, over many pings, the
//            minimum of each one-way difference separately:
//              a = min(t_rx - t1),  b = min(t4 - t_tx)
//              offset (phone - board) = (b - a) / 2
//            Minimising each direction on its own is the point: a BLE reply
//            waits for the next connection event, so a single round trip is
//            asymmetric by up to one interval (15-30 ms on iOS), while each
//            direction's minimum is a message that just made its event.
//
//            Pings are answered only while no start is being judged: READY,
//            countdown, "on your marks" (20-25 s, the window for the sync).
//            From "set" until the result the board ignores them.
//
// micros() wraps every ~71.6 min: the app must take differences modulo 2^32.
//
// WHY ONLY HERE, NOT ON THE XIAO. BLE was first put on the XIAO
// (AlgorithmRealTime) on 2026-10-15 and taken out the same day: ArduinoBLE on
// Seeed's mbed core needed one patch after another (gaps from the Cordio
// thread sharing the CPU with loop(), busy-waits, an unprotected receive
// buffer, a 256-byte buffer whose overflow hung the board with the buzzer on).
// The XIAO stamps samples in loop() and has no FIFO, so any CPU it gives to
// BLE costs timing. This board does not have that problem:
//  - The core's BLE library runs on NimBLE on the C3 (CONFIG_BT_NIMBLE_ENABLED
//    in the precompiled sdkconfig). notify() does not block: with no buffer
//    free it returns an error, so the XIAO's hang cannot happen here.
//  - The sample instant is stamped in the ISR and the sample waits in the
//    BMI270 FIFO (1.28 s): a late loop() delays a sample, it does not move or
//    lose it. What BLE can still do is delay the data-ready ISR itself - the
//    stamp jitter, measured with the radio on, is the check.
//  - The write callback runs in the NimBLE host task, not in loop(): the
//    reply it prepares is handed over under a critical section.
// Python_Tools/ble_monitor.py is the app's side of this protocol, from a Mac.
//
// Notifications are sent from loop(), right after a sample and only while the
// display has nothing to draw: the display's rule (never between two samples).
// ---------------------------------------------------------------------------
#include <BLEDevice.h>
#include <BLEServer.h>

enum BleEvent : uint8_t {
  BLE_EV_READY     = 0,
  BLE_EV_COUNTDOWN = 1,
  BLE_EV_MARKS     = 2,
  BLE_EV_SET       = 3,
  BLE_EV_GO        = 4,
  BLE_EV_RESULT    = 5,
  BLE_EV_ABORT     = 6,
  BLE_EV_OFF       = 7,
};

enum BleVerdict : uint8_t {
  BLE_V_VALID       = 0,
  BLE_V_FALSE_START = 1,
  BLE_V_NO_MOVEMENT = 2,
  BLE_V_UNUSABLE    = 3,
};

static const char* BLE_SERVICE_UUID = "F7280000-22EB-44D8-BE12-ECD2B6BDD709";
static const char* BLE_EVENT_UUID   = "F7280001-22EB-44D8-BE12-ECD2B6BDD709";
static const char* BLE_PING_UUID    = "F7280002-22EB-44D8-BE12-ECD2B6BDD709";
static const char* BLE_PONG_UUID    = "F7280003-22EB-44D8-BE12-ECD2B6BDD709";

static const uint8_t BLE_EVENT_MAX = 20;

static BLECharacteristic* bleEventChar = nullptr;
static BLECharacteristic* blePongChar = nullptr;

static bool bleReady = false;
// Set by the sketch: pings are answered only while this is true.
static volatile bool bleSyncAllowed = true;
static uint8_t bleEventCounter = 0;

struct BleQueued { uint8_t len; uint8_t data[BLE_EVENT_MAX]; };
static const uint8_t BLE_QUEUE_LEN = 4;
static BleQueued bleQ[BLE_QUEUE_LEN];
static uint8_t bleQHead = 0, bleQCount = 0;

// Written by the NimBLE host task, read by loop().
static portMUX_TYPE bleSyncMux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool bleSyncPending = false;
static uint8_t bleSyncReply[10];

static inline void blePut32(uint8_t* p, uint32_t v) {
  p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}

class BlePingCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    uint32_t tRx = micros();
    if (!bleSyncAllowed) return;
    String v = c->getValue();
    if (v.length() < 2) return;
    portENTER_CRITICAL(&bleSyncMux);
    bleSyncReply[0] = (uint8_t)v[0];
    bleSyncReply[1] = (uint8_t)v[1];
    blePut32(&bleSyncReply[2], tRx);
    bleSyncPending = true;
    portEXIT_CRITICAL(&bleSyncMux);
  }
};

class BleServerCallbacks : public BLEServerCallbacks {
  // The stack does not advertise again by itself after a disconnect.
  void onDisconnect(BLEServer*) override { BLEDevice::startAdvertising(); }
};

static bool bleBegin() {
  BLEDevice::init("ProStart");
  BLEServer* server = BLEDevice::createServer();
  if (server == nullptr) return false;
  server->setCallbacks(new BleServerCallbacks());
  BLEService* svc = server->createService(BLE_SERVICE_UUID);
  bleEventChar = svc->createCharacteristic(BLE_EVENT_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  BLECharacteristic* ping = svc->createCharacteristic(BLE_PING_UUID,
      BLECharacteristic::PROPERTY_WRITE_NR);
  blePongChar = svc->createCharacteristic(BLE_PONG_UUID,
      BLECharacteristic::PROPERTY_NOTIFY);
  ping->setCallbacks(new BlePingCallbacks());
  svc->start();
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(BLE_SERVICE_UUID);
  adv->setScanResponse(true);   // the name goes in the scan response
  BLEDevice::startAdvertising();
  bleReady = true;
  return true;
}

// Queues an event and makes it the readable value. payload may be null.
static void bleEvent(BleEvent type, const uint8_t* payload = nullptr, uint8_t n = 0) {
  if (!bleReady) return;
  if (n > BLE_EVENT_MAX - 2) n = BLE_EVENT_MAX - 2;
  if (bleQCount == BLE_QUEUE_LEN) {   // never expected; drop the oldest
    bleQHead = (bleQHead + 1) % BLE_QUEUE_LEN;
    bleQCount--;
  }
  BleQueued* e = &bleQ[(bleQHead + bleQCount) % BLE_QUEUE_LEN];
  e->data[0] = type;
  e->data[1] = ++bleEventCounter;
  if (n) memcpy(&e->data[2], payload, n);
  e->len = 2 + n;
  bleQCount++;
}

static void bleEventAt(BleEvent type, uint32_t tUs) {
  uint8_t p[4];
  blePut32(p, tUs);
  bleEvent(type, p, 4);
}

// One unit of BLE work: called right after a sample, never between two.
static void blePump() {
  if (!bleReady) return;
  if (bleSyncPending) {
    uint8_t reply[10];
    portENTER_CRITICAL(&bleSyncMux);
    memcpy(reply, bleSyncReply, sizeof(reply));
    bleSyncPending = false;
    portEXIT_CRITICAL(&bleSyncMux);
    blePut32(&reply[6], micros());
    blePongChar->setValue(reply, sizeof(reply));
    blePongChar->notify();
    return;
  }
  if (bleQCount) {
    BleQueued* e = &bleQ[bleQHead];
    bleEventChar->setValue(e->data, e->len);   // also the readable value
    bleEventChar->notify();
    bleQHead = (bleQHead + 1) % BLE_QUEUE_LEN;
    bleQCount--;
  }
}
