#include "UITask.h"

#include <Curve25519.h>
#include <SPIFFS.h>
#include <Utils.h>
#include <esp_random.h>
#include <target.h>

#include "../MyMesh.h"

using namespace helpandi;

namespace {

constexpr const char* kGroupFile = "/hi_group";
constexpr const char* kMembersFile = "/hi_members";
constexpr const char* kNextRequestKey = "next";
constexpr uint8_t kFlood = 0xFF;
constexpr unsigned long kScreenOnMs = 120000;
const BatteryModel kBattery{HI_BATTERY_MAH, HI_DRAW_MA};

RadioSettings radioFrom(const NodePrefs& p) { return RadioSettings(p.freq, p.bw, p.sf, p.cr); }

// Melodies in RTTTL, as MeshCore's buzzer plays them. Each can be told from the others across a
// room; none is harsh.
constexpr const char* kPressTune = "press:d=8,o=6,b=180:e,g";
constexpr const char* kOKTune = "ok:d=8,o=6,b=160:g";
constexpr const char* kSeenTune = "seen:d=8,o=6,b=140:c,e,g,4c7";
constexpr const char* kNotSentTune = "cross:d=4,o=5,b=100:g,e,g,e";
constexpr const char* kTapTune = "tap:d=16,o=6,b=200:c";
constexpr const char* kWarnTune = "warn:d=16,o=6,b=200:c,p,c";

}  // namespace

UITask::UITask(mesh::MainBoard* board, MultiSerialInterface* serial)
    : AbstractUITask(board, serial),
      _buttons(HI_LAYOUT_PRG_ONLY ? prgOnly() : threeButtons()),
      _engine(*this, RadioSettings(LORA_FREQ, LORA_BW, LORA_SF, LORA_CR), kBattery, 1) {}

void UITask::begin(DisplayDriver* display, SensorManager*, NodePrefs* prefs) {
  _display = display;
  _prefs = prefs;
#if !HI_LAYOUT_PRG_ONLY
  pinMode(HI_PIN_RED, INPUT_PULLUP);
  pinMode(HI_PIN_AMBER, INPUT_PULLUP);
  pinMode(HI_PIN_GREEN, INPUT_PULLUP);
#endif
  pinMode(PIN_USER_BTN, INPUT_PULLUP);
  pinMode(HI_PIN_MAINS, INPUT);
  pinMode(HI_PIN_LED, OUTPUT);
  _buzzer.begin();
  _buzzer.quiet(false);
  _nvs.begin("helpandi", false);
  _engine.setNextRequest(_nvs.getUShort(kNextRequestKey, 1));
  applyRadio();
  // No record of the hour before this start survives a power cut (section 8).
  _engine.coldStart(millis());
  loadProvisioning();
  _activeUntil = millis() + kScreenOnMs;
  if (_display) _display->turnOn();
}

// BoxPort

bool UITask::verify(const uint8_t key[32], const uint8_t sig[64], const uint8_t* message, size_t length) {
  return mesh::Identity(key).verify(sig, message, int(length));
}

void UITask::sign(uint8_t sig[64], const uint8_t* message, size_t length) {
  the_mesh.self_id.sign(sig, message, int(length));
}

bool UITask::sharedSecret(uint8_t out[32], const uint8_t theirs[32]) {
  // MeshCore's private key is SHA-512 of the seed, clamped: its first 32 bytes are an X25519
  // scalar, so the one key both signs and seals (DESIGN.md, section 6).
  uint8_t prv[PRV_KEY_SIZE];
  if (the_mesh.self_id.writeTo(prv, sizeof prv) != PRV_KEY_SIZE) return false;
  return Curve25519::eval(out, prv, theirs);
}

void UITask::randomBytes(uint8_t* out, size_t length) { esp_fill_random(out, length); }

bool UITask::sendGroup(const uint8_t secret[16], const uint8_t* payload, size_t length) {
  mesh::GroupChannel channel;
  memset(channel.secret, 0, sizeof channel.secret);
  memcpy(channel.secret, secret, kChannelSecretBytes);
  mesh::Utils::sha256(channel.hash, sizeof channel.hash, channel.secret, kChannelSecretBytes);
  return the_mesh.sendGroupData(channel, nullptr, kFlood, kMeshDataType, payload, int(length));
}

uint32_t UITask::airtimeMs(size_t payloadLength) {
  return radioFrom(*_prefs).airtimeMs(meshPacketBytes(int(payloadLength)));
}

void UITask::toPhone(const uint8_t* frame, size_t length) {
  if (!hasConnection() || length + 1 > MAX_FRAME_SIZE) return;
  uint8_t out[MAX_FRAME_SIZE];
  out[0] = kPushFrame;
  memcpy(out + 1, frame, length);
  _interfaceManager->writeFrame(out, length + 1);
}

void UITask::saveNextRequest(uint16_t next) { _nvs.putUShort(kNextRequestKey, next); }

// Provisioning, kept in flash as the command bytes the phone sent.

bool UITask::saveFile(const char* path, const uint8_t* data, size_t length) {
  File f = SPIFFS.open(path, "w");
  if (!f) return false;
  bool ok = f.write(data, length) == length;
  f.close();
  return ok;
}

void UITask::loadProvisioning() {
  uint8_t buf[kSetGroupBytes];
  File g = SPIFFS.open(kGroupFile, "r");
  if (g) {
    size_t n = g.read(buf, sizeof buf);
    g.close();
    _haveGroup = parseSetGroup(buf, n, _group);
  }
  File m = SPIFFS.open(kMembersFile, "r");
  if (m) {
    uint8_t chunk[7 + kMembersPerChunk * kMemberBytes];
    bool complete = false;
    MemberList list;
    while (m.available()) {
      size_t n = m.read(chunk, 7);
      if (n != 7) break;
      size_t count = chunk[6] - chunk[5] < kMembersPerChunk ? chunk[6] - chunk[5] : kMembersPerChunk;
      n += m.read(chunk + 7, count * kMemberBytes);
      if (!parseMembersChunk(chunk, n, list, complete)) break;
    }
    m.close();
    if (complete) {
      _members = list;
      _haveMembers = true;
    }
  }
  provisionIfReady();
}

void UITask::provisionIfReady() {
  if (_haveGroup && _haveMembers) _engine.provision(_group, _members);
}

void UITask::reply(uint8_t code) {
  uint8_t out[2] = {kRespOK, 0};
  size_t n = 1;
  if (code != kRespOK) {
    out[0] = kRespError;
    out[1] = code;
    n = 2;
  }
  _interfaceManager->writeFrame(out, n);
}

bool UITask::onUnhandledCmdFrame(const uint8_t* frame, size_t len) {
  switch (frame[0]) {
  case kCmdInfo: {
    uint8_t out[32];
    size_t i = 0;
    out[i++] = kRespInfo;
    out[i++] = kHelpandiProtocol;
    out[i++] = _engine.provisioned() ? 1 : 0;
    uint32_t unit = _group.unit;
    memcpy(out + i, &unit, 4);
    i += 4;
    uint16_t member = _group.member, next = _engine.nextRequest();
    memcpy(out + i, &member, 2);
    i += 2;
    memcpy(out + i, &next, 2);
    i += 2;
    Screen s = _engine.screen();
    out[i++] = uint8_t(s.mains);
    memcpy(out + i, &_millivolts, 2);
    i += 2;
    uint16_t hours = uint16_t(s.hoursLeft);
    memcpy(out + i, &hours, 2);
    i += 2;
    out[i++] = uint8_t(_group.antenna);
    int cap = 0;
    out[i++] = uint8_t(_engine.powerCap(HI_AMPLIFIER_GAIN_DB, -9, MAX_LORA_TX_POWER, cap) ? int8_t(cap) : int8_t(-128));
    out[i++] = uint8_t(_members.count);
    out[i++] = uint8_t(_engine.callCount());
    _interfaceManager->writeFrame(out, i);
    return true;
  }
  case kCmdSetGroup: {
    GroupSettings g{};
    if (!parseSetGroup(frame, len, g) || !saveFile(kGroupFile, frame, len)) {
      reply(kErrorBadArgument);
      return true;
    }
    _group = g;
    _haveGroup = true;
    provisionIfReady();
    reply(kRespOK);
    return true;
  }
  case kCmdSetMembers: {
    bool complete = false;
    if (!parseMembersChunk(frame, len, _building, complete)) {
      reply(kErrorBadArgument);
      return true;
    }
    if (complete) {
      uint8_t chunk[7 + kMembersPerChunk * kMemberBytes];
      File f = SPIFFS.open(kMembersFile, "w");
      for (size_t i = 0; f && i < _building.count; i += kMembersPerChunk)
        f.write(chunk, writeMembersChunk(_building, i, chunk, sizeof chunk));
      if (f) f.close();
      _members = _building;
      _haveMembers = true;
      provisionIfReady();
    }
    reply(kRespOK);
    return true;
  }
  case kCmdGetCalls: {
    for (size_t i = 0; i < _engine.callCount(); i++) {
      const OutgoingCall& c = _engine.call(i);
      uint8_t out[10];
      out[0] = kRespCall;
      memcpy(out + 1, &c.number, 2);
      out[3] = uint8_t(c.colour);
      memcpy(out + 4, &c.pressedAt, 4);
      out[8] = uint8_t(c.status());
      out[9] = uint8_t(c.ackCount);
      _interfaceManager->writeFrame(out, sizeof out);
    }
    uint8_t end = kRespEndOfCalls;
    _interfaceManager->writeFrame(&end, 1);
    return true;
  }
  case kCmdRouteResult: {
    RouteResult r{};
    if (!parseRouteResult(frame, len, r)) {
      reply(kErrorBadArgument);
      return true;
    }
    _engine.phoneRoute(r.request, r.sent);
    reply(kRespOK);
    return true;
  }
  case kCmdForget:
    SPIFFS.remove(kGroupFile);
    SPIFFS.remove(kMembersFile);
    _haveGroup = _haveMembers = false;
    _engine.forget();
    reply(kRespOK);
    return true;
  default:
    return false;
  }
}

void UITask::onChannelDataRecv(mesh::Packet*, const mesh::GroupChannel& channel, uint16_t data_type, const uint8_t* data,
                               size_t data_len) {
  if (data_type != kMeshDataType || !_engine.provisioned()) return;
  bool current = memcmp(channel.secret, _group.channelSecret, kChannelSecretBytes) == 0;
  bool old = _group.hasOldSecret() && memcmp(channel.secret, _group.oldChannelSecret, kChannelSecretBytes) == 0;
  if (current || old) _engine.heard(data, data_len);
}

// The loop

uint8_t UITask::buttonLevels() const {
  uint8_t levels = 0;
#if !HI_LAYOUT_PRG_ONLY
  if (digitalRead(HI_PIN_RED) == LOW) levels |= 1 << uint8_t(Input::red);
  if (digitalRead(HI_PIN_AMBER) == LOW) levels |= 1 << uint8_t(Input::amber);
  if (digitalRead(HI_PIN_GREEN) == LOW) levels |= 1 << uint8_t(Input::green);
#endif
  if (digitalRead(PIN_USER_BTN) == LOW) levels |= 1 << uint8_t(Input::prg);
  return levels;
}

void UITask::play(Sound s) {
  switch (s) {
  case Sound::press: _buzzer.play(kPressTune); break;
  case Sound::ok: _buzzer.play(kOKTune); break;
  case Sound::seen: _buzzer.play(kSeenTune); break;
  case Sound::notSent: _buzzer.play(kNotSentTune); break;
  case Sound::none: break;
  }
}

// Called every second, so a setting changed from the app or the console is capped within one.
void UITask::applyRadio() {
  if (_prefs->freq != _freq || _prefs->bw != _bw || _prefs->sf != _sf || _prefs->cr != _cr) {
    _freq = _prefs->freq;
    _bw = _prefs->bw;
    _sf = _prefs->sf;
    _cr = _prefs->cr;
    _engine.setRadio(radioFrom(*_prefs));
  }
  int cap = 0;
  if (_engine.powerCap(HI_AMPLIFIER_GAIN_DB, -9, MAX_LORA_TX_POWER, cap) && _prefs->tx_power_dbm > cap) {
    _prefs->tx_power_dbm = int8_t(cap);
    radio_driver.setTxPower(int8_t(cap));
    the_mesh.savePrefs();
  }
}

void UITask::loop() {
  unsigned long now = millis();
  uint32_t wall = rtc_clock.getCurrentTime();

  Event events[ButtonMachine::kMaxEvents];
  size_t n = _buttons.update(now, buttonLevels(), events);
  if (n) _activeUntil = now + kScreenOnMs;
  for (size_t i = 0; i < n; i++) {
    switch (events[i].type) {
    case Event::Type::send: _engine.press(events[i].colour, now, wall, hasConnection()); break;
    case Event::Type::countdownStarted:
    case Event::Type::tap: _buzzer.play(kTapTune); break;
    case Event::Type::warn: _buzzer.play(kWarnTune); break;
    case Event::Type::countdownStopped: _buzzer.play(kOKTune); break;
    }
  }

  _engine.tick(now, wall);

  if (now >= _nextPower) {
    _nextPower = now + 1000;
    if (now >= _nextBattery) {
      _nextBattery = now + 60000;
      _millivolts = getBattMilliVolts();
    }
    _engine.power(now, wall, digitalRead(HI_PIN_MAINS) == HIGH, _millivolts);
    applyRadio();
  }

  for (Sound s = _engine.takeSound(); s != Sound::none; s = _engine.takeSound()) {
    play(s);
    _activeUntil = now + kScreenOnMs;
  }
  _buzzer.loop();

  Screen s = _engine.screen();
  bool open = s.hasCall && (s.status == CallerStatus::sending || s.status == CallerStatus::waitingForResponder ||
                            s.status == CallerStatus::notSent);
  bool blink = s.hasCall && s.status == CallerStatus::notSent;
  digitalWrite(HI_PIN_LED, open && (!blink || (now / 500) % 2) ? HIGH : LOW);

  if (_display == nullptr) return;
  bool wanted = open || _buttons.counting() || s.mains == PowerMonitor::Mains::off || now < _activeUntil;
  if (wanted && !_display->isOn()) _display->turnOn();
  if (!wanted && _display->isOn()) _display->turnOff();
  if (_display->isOn() && now >= _nextDraw) {
    _nextDraw = now + 250;
    draw();
  }
}

void UITask::drawCross(int x, int y, int size) {
  for (int i = 0; i < size; i++) {
    _display->fillRect(x + i, y + i, 2, 2);
    _display->fillRect(x + size - 1 - i, y + i, 2, 2);
  }
}

void UITask::draw() {
  Screen s = _engine.screen();
  int w = _display->width();
  _display->startFrame();
  _display->setTextSize(1);
  _display->setColor(UIColor::primary_txt);
  char line[40];
  _display->setCursor(0, 0);
  _display->print("Help&I");
  if (hasConnection()) {
    _display->drawTextRightAlign(w, 0, "phone");
  } else {
    // MeshCore's random pairing code, which the phone needs to connect.
    snprintf(line, sizeof line, "code %lu", (unsigned long)the_mesh.getBLEPin());
    _display->drawTextRightAlign(w, 0, line);
  }

  if (_buttons.counting()) {
    snprintf(line, sizeof line, "%lu", (unsigned long)_buttons.secondsLeft(millis()));
    _display->setTextSize(3);
    _display->drawTextCentered(w / 2, 14, line);
    _display->setTextSize(1);
    _display->drawTextCentered(w / 2, 44, "Help goes at 0.");
    _display->drawTextCentered(w / 2, 54, "Press again to stop.");
  } else if (!s.provisioned) {
    _display->setCursor(0, 14);
    _display->printWordWrap(kNotSetUpWords, w);
  } else if (s.hasCall) {
    int textWidth = s.status == CallerStatus::notSent ? w - 30 : w;
    _display->setCursor(0, 14);
    _display->printWordWrap(statusWords(s.status), textWidth);
    if (s.status == CallerStatus::notSent) drawCross(w - 26, 18, 24);
  } else {
    _display->setCursor(0, 14);
    _display->printWordWrap(kSupplementWords, w);
    snprintf(line, sizeof line, "Unit %lu", (unsigned long)_group.unit);
    _display->drawTextLeftAlign(0, 40, line);
  }

  if (s.mains == PowerMonitor::Mains::off && !_buttons.counting()) {
    if (s.hoursLeft) {
      snprintf(line, sizeof line, "Power cut: about %lu h", (unsigned long)s.hoursLeft);
    } else {
      snprintf(line, sizeof line, "Power cut");
    }
    _display->drawTextLeftAlign(0, _display->height() - 10, line);
  }
  _display->endFrame();
}
