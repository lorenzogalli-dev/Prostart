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
//   data     F7280004-...  notify. The last start's recording, sent after the
//            result (2026-10-16: the board keeps nothing on flash any more -
//            the app is where runs are saved). Every packet is <= MTU-3 bytes:
//            [0] u8 kind
//            RUN_INFO (1)  [1..4] u32 boot id (random per power-up: run ids
//                            restart at 1 after a reboot, the pair does not)
//                          [5..6] u16 run id   [7..8] u16 n samples
//                          [9..10] u16 preroll (samples before "set")
//                          [11..14] on  [15..18] set  [19..22] go
//                          [23..26] arm t_us   (all board micros, 0 = none)
//                          [27..28] u16 arm peak, 0.01 mg
//                          [29] u8 flags: 1 arm valid, 2 arm on the cap,
//                               4 truncated, 8 timing check passed
//                          [30] u8 verdict (BleVerdict)
//                          [31..34] i32 reaction us  [35..38] u32 onset t_us
//                          [39..40] u16 dropped  [41..42] u16 gaps
//                          [43..46] u32 max gap us  [47..48] u16 clock step us
//                          [49..50] u16 ODR Hz
//            SAMPLES (2)   [1..2] u16 run id  [3..4] u16 index of the first
//                          then k x { u32 t_us, i16 x, i16 y, i16 z } (raw,
//                          2048 LSB/g), k = (MTU - 3 - 5) / 10
//            RUN_END (3)   [1..2] u16 run id  [3..4] u16 n
//            NO_RUN (4)    the run asked for is not held (any more)
//   ctrl     F7280005-...  write, app -> board
//            GET (1)  [1..2] run id (0 = the one held)  [3..4] from
//                     [5..6] to, exclusive (0xFFFF = to the end). Sends
//                     RUN_INFO, the samples [from, to), RUN_END.
//            ACK (2)  [1..2] run id: the app has it all, the board may let go.
//            After a result the board pushes the whole run by itself to a
//            connected app; the app GETs whatever it is missing, then ACKs.
//            The run is kept in RAM until the ACK or the next start's "set".
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
//    BMI270 FIFO (0.42 s): a late loop() delays a sample, it does not move or
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
static const char* BLE_DATA_UUID    = "F7280004-22EB-44D8-BE12-ECD2B6BDD709";
static const char* BLE_CTRL_UUID    = "F7280005-22EB-44D8-BE12-ECD2B6BDD709";

enum BleDataKind : uint8_t { BLE_D_INFO = 1, BLE_D_SAMPLES = 2, BLE_D_END = 3, BLE_D_NO_RUN = 4 };
enum BleCtrl : uint8_t { BLE_C_GET = 1, BLE_C_ACK = 2 };

static const uint8_t BLE_EVENT_MAX = 20;

static BLECharacteristic* bleEventChar = nullptr;
static BLECharacteristic* blePongChar = nullptr;
static BLECharacteristic* bleDataChar = nullptr;
static BLEServer* bleServer = nullptr;

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

// A ctrl write, handed to loop() the same way (one pending; a newer one wins).
static volatile bool bleCtrlPending = false;
static uint8_t bleCtrlReq[8];
static uint8_t bleCtrlLen = 0;

// Link changes, for the screen's "app connected" line.
static volatile uint8_t bleConnected = 0;
static volatile bool bleLinkChanged = false;

// Set inside notify() by the status callback: did the last data packet go?
static bool bleDataLastOk = false;

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

class BleCtrlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue();
    if (v.length() < 1) return;
    portENTER_CRITICAL(&bleSyncMux);
    bleCtrlLen = v.length() < sizeof(bleCtrlReq) ? v.length() : sizeof(bleCtrlReq);
    memcpy(bleCtrlReq, v.c_str(), bleCtrlLen);
    bleCtrlPending = true;
    portEXIT_CRITICAL(&bleSyncMux);
  }
};

class BleDataCallbacks : public BLECharacteristicCallbacks {
  // Called synchronously from notify(): the out-of-buffers case is ERROR_GATT,
  // and the packet is then sent again later rather than lost.
  void onStatus(BLECharacteristic*, Status s, uint32_t) override {
    bleDataLastOk = (s == SUCCESS_NOTIFY);
  }
};

class BleServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    bleConnected = 1;
    bleLinkChanged = true;
  }
  // The stack does not advertise again by itself after a disconnect.
  void onDisconnect(BLEServer*) override {
    bleConnected = 0;
    bleLinkChanged = true;
    BLEDevice::startAdvertising();
  }
};

static bool bleBegin() {
  BLEDevice::init("ProStart");
  // Bigger packets for the recording (iOS settles at 185, ~18 samples each).
  BLEDevice::setMTU(247);
  BLEServer* server = BLEDevice::createServer();
  if (server == nullptr) return false;
  bleServer = server;
  server->setCallbacks(new BleServerCallbacks());
  BLEService* svc = server->createService(BLE_SERVICE_UUID);
  bleEventChar = svc->createCharacteristic(BLE_EVENT_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  BLECharacteristic* ping = svc->createCharacteristic(BLE_PING_UUID,
      BLECharacteristic::PROPERTY_WRITE_NR);
  blePongChar = svc->createCharacteristic(BLE_PONG_UUID,
      BLECharacteristic::PROPERTY_NOTIFY);
  ping->setCallbacks(new BlePingCallbacks());
  bleDataChar = svc->createCharacteristic(BLE_DATA_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  bleDataChar->setCallbacks(new BleDataCallbacks());
  BLECharacteristic* ctrl = svc->createCharacteristic(BLE_CTRL_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  ctrl->setCallbacks(new BleCtrlCallbacks());
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

// Bytes a data packet may carry on this link (ATT MTU minus its 3-byte header).
static uint16_t bleDataRoom() {
  if (!bleReady || !bleConnected || bleServer == nullptr) return 0;
  uint16_t mtu = bleServer->getPeerMTU(bleServer->getConnId());
  return mtu > 3 ? mtu - 3 : 0;
}

// One data packet. False if it did not go (no link, or the stack's buffers are
// full): the caller sends it again later.
static bool bleDataSend(const uint8_t* p, uint16_t n) {
  if (bleDataRoom() < n || bleDataChar == nullptr) return false;
  bleDataLastOk = false;
  bleDataChar->setValue((uint8_t*)p, n);
  bleDataChar->notify();
  return bleDataLastOk;
}

// The pending ctrl write, if any, into req (up to 8 bytes). Its length, or 0.
static uint8_t bleTakeCtrl(uint8_t* req) {
  if (!bleCtrlPending) return 0;
  portENTER_CRITICAL(&bleSyncMux);
  uint8_t n = bleCtrlLen;
  memcpy(req, bleCtrlReq, n);
  bleCtrlPending = false;
  portEXIT_CRITICAL(&bleSyncMux);
  return n;
}

// One unit of BLE work: called right after a sample, never between two.
// True if it sent something (the recording then waits for the next slot).
static bool blePump() {
  if (!bleReady) return false;
  if (bleSyncPending) {
    uint8_t reply[10];
    portENTER_CRITICAL(&bleSyncMux);
    memcpy(reply, bleSyncReply, sizeof(reply));
    bleSyncPending = false;
    portEXIT_CRITICAL(&bleSyncMux);
    blePut32(&reply[6], micros());
    blePongChar->setValue(reply, sizeof(reply));
    blePongChar->notify();
    return true;
  }
  if (bleQCount) {
    BleQueued* e = &bleQ[bleQHead];
    bleEventChar->setValue(e->data, e->len);   // also the readable value
    bleEventChar->notify();
    bleQHead = (bleQHead + 1) % BLE_QUEUE_LEN;
    bleQCount--;
    return true;
  }
  return false;
}
