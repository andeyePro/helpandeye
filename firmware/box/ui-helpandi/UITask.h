// Help&I's user interface task for MeshCore's companion firmware: the buttons, buzzer, screen,
// LED, mains and battery pins, the Help&I companion commands and the group channel, all wired
// to the portable core (core/box.hpp). MeshCore's radio, Bluetooth and contacts stay as they are.
//
// UNTESTED ON HARDWARE: compiled for the Heltec V4, not yet run on one.
#pragma once

#include <Arduino.h>
#include <MeshCore.h>
#include <Preferences.h>
#include <helpers/MultiSerialInterface.h>
#include <helpers/SensorManager.h>
#include <helpers/ui/DisplayDriver.h>
#include <helpers/ui/buzzer.h>

#include "../AbstractUITask.h"
#include "../NodePrefs.h"
#include "core/box.hpp"
#include "core/buttons.hpp"

class UITask : public AbstractUITask, private helpandi::BoxPort {
public:
  UITask(mesh::MainBoard* board, MultiSerialInterface* serial);
  void begin(DisplayDriver* display, SensorManager* sensors, NodePrefs* prefs);

  // MyMesh::Listener
  void onMessageRecv(mesh::Packet*, const ContactInfo&, uint8_t, uint32_t, const char*) override {}
  void onChannelMessageRecv(mesh::Packet*, ChannelDetails&, const char*) override {}
  void onQueueSizeChanged(int) override {}
  void onChannelDataRecv(mesh::Packet* pkt, const mesh::GroupChannel& channel, uint16_t data_type, const uint8_t* data,
                         size_t data_len) override;
  bool onUnhandledCmdFrame(const uint8_t* frame, size_t len) override;

  // AbstractUITask
  void notify(UIEventType) override {}
  void loop() override;

private:
  // BoxPort
  bool verify(const uint8_t key[32], const uint8_t sig[64], const uint8_t* message, size_t length) override;
  void sign(uint8_t sig[64], const uint8_t* message, size_t length) override;
  bool sharedSecret(uint8_t out[32], const uint8_t theirs[32]) override;
  void randomBytes(uint8_t* out, size_t length) override;
  bool sendGroup(const uint8_t secret[16], const uint8_t* payload, size_t length) override;
  uint32_t airtimeMs(size_t payloadLength) override;
  void toPhone(const uint8_t* frame, size_t length) override;
  void saveNextRequest(uint16_t next) override;

  uint64_t now() const;
  uint8_t buttonLevels() const;
  void play(helpandi::Sound s);
  void keep(uint64_t now);
  void sleep(uint64_t now);
  void loadProvisioning();
  void provisionIfReady();
  void listenOn(const uint8_t secret[16]);
  bool saveFile(const char* path, const uint8_t* data, size_t length);
  void reply(uint8_t code);
  void applyRadio();
  void draw();
  void drawCross(int x, int y, int size);

  DisplayDriver* _display = nullptr;
  NodePrefs* _prefs = nullptr;
  genericBuzzer _buzzer;
  Preferences _nvs;
  helpandi::ButtonMachine _buttons;
  helpandi::BoxEngine _engine;
  helpandi::GroupSettings _group{};
  helpandi::MemberList _members;
  helpandi::MemberList _building;
  bool _haveGroup = false, _haveMembers = false;
  // The monotonic clock carries on across deep sleep and a reset (section 10).
  uint64_t _monoOffset = 0;
  uint64_t _nextPower = 0, _nextBattery = 0, _nextDraw = 0, _activeUntil = 0;
  uint16_t _millivolts = 0;
  float _freq = 0, _bw = 0;
  uint8_t _sf = 0, _cr = 0;
};
