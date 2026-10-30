#include "UITask.h"

#include <Curve25519.h>
#include <SPIFFS.h>
#include <Utils.h>
#include <driver/rtc_io.h>
#include <esp_random.h>
#include <esp_sleep.h>
#include <esp_timer.h>
#include <sys/time.h>
#include <target.h>

#include "../MyMesh.h"

using namespace helpandi;

namespace {

constexpr const char* kGroupFile = "/hi_group";
constexpr const char* kMembersFile = "/hi_members";
constexpr const char* kNextRequestKey = "next";
// The names as chunks, each after its length byte. In NVS, not SPIFFS: NVS can be encrypted
// under flash encryption and SPIFFS cannot (DESIGN.md, section 16).
constexpr const char* kNamesKey = "names";
constexpr size_t kNamesBlobBytes = kMaxMembers / kNamesPerChunk * 8 + kMaxMembers * (3 + kMaxNameBytes);
constexpr uint8_t kFlood = 0xFF;
constexpr uint64_t kScreenOnMs = 120000;
constexpr const char* kChannelName = "Help&I";
const BatteryDraw kDraw{HI_BATTERY_MAH, HI_DRAW_AWAKE_MA, HI_DRAW_ASLEEP_UA};

// The buttons that wake the board from deep sleep, all RTC pins (section 5). Inside the box PRG
// cannot be reached, so it is a wake source only on a plain board.
struct WakeButton {
  int pin;
  Input input;
};
#if HI_LAYOUT_PRG_ONLY
constexpr WakeButton kWakeButtons[] = {{PIN_USER_BTN, Input::prg}};
#else
constexpr WakeButton kWakeButtons[] = {{HI_PIN_RED, Input::red}, {HI_PIN_AMBER, Input::amber}, {HI_PIN_GREEN, Input::green}};
#endif

// The buttons that woke the board, as ButtonMachine takes them: that press counts even if it was
// let go before the core first ran.
uint8_t wokenBy() {
  if (esp_sleep_get_wakeup_cause() != ESP_SLEEP_WAKEUP_EXT1) return 0;
  uint64_t pins = esp_sleep_get_ext1_wakeup_status();
  uint8_t woke = 0;
  for (const WakeButton& b : kWakeButtons)
    if (pins >> b.pin & 1) woke |= uint8_t(1 << uint8_t(b.input));
  return woke;
}

// The core's copy of what survives deep sleep and a reset, with the clock it was taken at, in
// RTC memory that a reset leaves alone and a power-on leaves as it was: the core's checksum
// tells the two apart, and the clock is written with the copy. The system clock keeps running
// through deep sleep, and nothing can set it meanwhile, so it measures the time asleep.
struct RetainedCopy {
  uint64_t monoMs;
  int64_t wallUs;
  uint8_t state[BoxEngine::kRetainedBytes];
};
RTC_NOINIT_ATTR RetainedCopy retained;
static_assert(sizeof retained <= 6144, "the ESP32-S3 has 8 KB of RTC slow memory, part of it ESP-IDF's");

int64_t wallUs() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return int64_t(tv.tv_sec) * 1000000 + tv.tv_usec;
}

// millis() is 32 bits on the ESP32 and wraps after 49.7 days; the core's resends and its airtime
// log need a clock that only goes up for as long as the box is on.
uint64_t monoMs() { return uint64_t(esp_timer_get_time() / 1000); }

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
      _buttons(HI_LAYOUT_PRG_ONLY ? prgOnly() : threeButtons(), wokenBy()),
      _engine(*this, RadioSettings(LORA_FREQ, LORA_BW, LORA_SF, LORA_CR), batteryModel(kDraw, HI_MAINS_SENSED != 0), 1) {}

uint64_t UITask::now() const { return monoMs() + _monoOffset; }

void UITask::begin(DisplayDriver* display, SensorManager*, NodePrefs* prefs) {
  _display = display;
  _prefs = prefs;
  bool slept = esp_reset_reason() == ESP_RST_DEEPSLEEP;
  if (slept) {
    // Back from the RTC controller to ordinary GPIO, as HeltecV4Board::begin does for DIO1.
    for (const WakeButton& b : kWakeButtons) rtc_gpio_deinit(gpio_num_t(b.pin));
    rtc_gpio_deinit(gpio_num_t(HI_PIN_MAINS));
  }
#if !HI_LAYOUT_PRG_ONLY
  pinMode(HI_PIN_RED, INPUT_PULLUP);
  pinMode(HI_PIN_AMBER, INPUT_PULLUP);
  pinMode(HI_PIN_GREEN, INPUT_PULLUP);
  pinMode(HI_PIN_MAINS, INPUT);
#else
  // A plain board has no mains divider: pulled up it reads mains on, and grounding the pin
  // stages a power cut (MANUAL-TESTS 58).
  pinMode(HI_PIN_MAINS, INPUT_PULLUP);
#endif
  pinMode(PIN_USER_BTN, INPUT_PULLUP);
  pinMode(HI_PIN_LED, OUTPUT);
  _buzzer.begin();
  _buzzer.quiet(false);
  _nvs.begin("helpandi", false);
  _engine.setNextRequest(_nvs.getUShort(kNextRequestKey, 1));
  applyRadio();
  if (_engine.resume(retained.state)) {
    _monoOffset = retained.monoMs + (slept ? uint64_t(wallUs() - retained.wallUs) / 1000 : 0) - monoMs();
  } else {
    // No record of the hour before this start survives a power cut (section 8).
    _engine.coldStart(now());
  }
  loadProvisioning();
  // A wake to read the battery shows nothing: the box goes back to sleep in a moment.
  bool quiet = esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_TIMER;
  _activeUntil = quiet ? now() : now() + kScreenOnMs;
  if (_display && quiet) _display->turnOff();
  if (_display && !quiet) _display->turnOn();
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

void UITask::saveNames() {
  if (!_names.count) {
    _nvs.remove(kNamesKey);
    return;
  }
  uint8_t blob[kNamesBlobBytes];
  size_t n = 0;
  for (size_t i = 0; i < _names.count; i += kNamesPerChunk) {
    size_t len = writeNamesChunk(_names, i, blob + n + 1, sizeof blob - n - 1);
    blob[n] = uint8_t(len);
    n += 1 + len;
  }
  _nvs.putBytes(kNamesKey, blob, n);
}

void UITask::loadProvisioning() {
  uint8_t names[kNamesBlobBytes];
  size_t total = _nvs.getBytes(kNamesKey, names, sizeof names);
  NameList list;
  bool whole = false;
  for (size_t at = 0; at < total && at + 1 + names[at] <= total; at += 1 + names[at])
    if (!parseNamesChunk(names + at + 1, names[at], list, whole)) break;
  if (whole) _names = list;

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

// MeshCore decrypts a group datagram only for a channel in its own table, so the box puts the
// group's channel there itself (and the old one during a changeover) rather than wait for a phone
// to set it: the buttons work with no phone. Not saved: MeshCore reloads its table at start and
// this runs again from the flash copy of the group.
void UITask::listenOn(const uint8_t secret[16]) {
  ChannelDetails ch{};
  memcpy(ch.channel.secret, secret, kChannelSecretBytes);
  mesh::Utils::sha256(ch.channel.hash, sizeof ch.channel.hash, ch.channel.secret, kChannelSecretBytes);
  int idx = the_mesh.findChannelIdx(ch.channel);
  for (int i = 0; idx < 0 && i < MAX_GROUP_CHANNELS; i++) {
    ChannelDetails slot;
    if (the_mesh.getChannel(i, slot) && slot.name[0] == 0) idx = i;
  }
  if (idx < 0) return;
  strcpy(ch.name, kChannelName);
  the_mesh.setChannel(idx, ch);
}

void UITask::provisionIfReady() {
  if (_haveGroup) {
    listenOn(_group.channelSecret);
    if (_group.hasOldSecret()) listenOn(_group.oldChannelSecret);
  }
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
    uint8_t out[64];
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
    out[i++] = uint8_t(uint8_t(s.mains) | (HI_MAINS_SENSED ? 0 : 4));
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
    // The box's sealing key, for its memberAdded: the X25519 public key of the same scalar
    // sharedSecret uses (DESIGN.md, section 6). All zero if the board's key cannot be read.
    uint8_t prv[PRV_KEY_SIZE];
    memset(out + i, 0, kKeyBytes);
    if (the_mesh.self_id.writeTo(prv, sizeof prv) == PRV_KEY_SIZE) Curve25519::eval(out + i, prv, nullptr);
    i += kKeyBytes;
    out[i++] = uint8_t(_names.count);
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
  case kCmdSetNames: {
    bool complete = false;
    if (!parseNamesChunk(frame, len, _buildingNames, complete)) {
      reply(kErrorBadArgument);
      return true;
    }
    if (complete) {
      _names = _buildingNames;
      saveNames();
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
    _nvs.remove(kNamesKey);
    _names.count = 0;
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

void UITask::keep(uint64_t now) {
  retained.monoMs = now;
  retained.wallUs = wallUs();
  _engine.retain(retained.state);
}

// Deep sleep until a button, the mains coming back or the next battery reading (section 10).
// As ESP32Board::enterDeepSleep and HeltecV4Board::powerOff leave the board, with the wake
// sources added; neither can be called, as both clear every wake source before sleeping.
void UITask::sleep(uint64_t now) {
  keep(now);
  if (_display) _display->turnOff();
  digitalWrite(HI_PIN_LED, LOW);
  radio_driver.powerOff();
  digitalWrite(P_LORA_NSS, HIGH);
  rtc_gpio_hold_en(gpio_num_t(P_LORA_NSS));
  digitalWrite(P_LORA_PA_POWER, LOW);
  rtc_gpio_hold_en(gpio_num_t(P_LORA_PA_POWER));
  Serial.flush();
  esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);
  // The RTC peripherals stay powered so the pull-ups hold and the mains pin can be watched.
  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
  uint64_t buttons = 0;
  for (const WakeButton& b : kWakeButtons) {
    rtc_gpio_pullup_en(gpio_num_t(b.pin));
    rtc_gpio_pulldown_dis(gpio_num_t(b.pin));
    buttons |= 1ULL << b.pin;
  }
  esp_sleep_enable_ext1_wakeup(buttons, ESP_EXT1_WAKEUP_ANY_LOW);
  rtc_gpio_pulldown_dis(gpio_num_t(HI_PIN_MAINS));
#if HI_LAYOUT_PRG_ONLY
  rtc_gpio_pullup_en(gpio_num_t(HI_PIN_MAINS));
#else
  rtc_gpio_pullup_dis(gpio_num_t(HI_PIN_MAINS));
#endif
#if HI_MAINS_SENSED
  esp_sleep_enable_ext0_wakeup(gpio_num_t(HI_PIN_MAINS), 1);
#endif
  esp_sleep_enable_timer_wakeup(uint64_t(kSleepS) * 1000000);
  esp_deep_sleep_start();
}

void UITask::loop() {
  uint64_t now = this->now();
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
    _engine.power(now, wall, digitalRead(HI_PIN_MAINS) == HIGH, _millivolts, hasConnection());
    applyRadio();
    keep(now);
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

  if (_display) {
    // Not for a power cut on its own: on battery the box sleeps, and a wake to read the battery
    // must not light the screen.
    bool wanted = open || _buttons.counting() || now < _activeUntil;
    if (wanted && !_display->isOn()) _display->turnOn();
    if (!wanted && _display->isOn()) _display->turnOff();
    if (_display->isOn() && now >= _nextDraw) {
      _nextDraw = now + 250;
      draw();
    }
  }

  // Nothing of MeshCore's own may be waiting either: a frame queued for the radio, or one on air.
  if (_engine.canSleep(hasConnection()) && !_buttons.counting() && !_buzzer.isPlaying() && now >= _activeUntil &&
      !the_mesh.hasPendingWork() && radio_driver.isInRecvMode())
    sleep(now);
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
    snprintf(line, sizeof line, "%lu", (unsigned long)_buttons.secondsLeft(now()));
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
    const char* words = statusWords(s.status);
    if (s.status == CallerStatus::seen) {
      // The first responder to see it, by name when the box holds one (section 6).
      const OutgoingCall& c = _engine.call(_engine.callCount() - 1);
      seenByWords(_names.find(c.acknowledgedBy[0]), line, sizeof line);
      words = line;
    }
    _display->setCursor(0, 14);
    _display->printWordWrap(words, textWidth);
    if (s.status == CallerStatus::notSent) drawCross(w - 26, 18, 24);
  } else {
    _display->setCursor(0, 14);
    _display->printWordWrap(kSupplementWords, w);
    snprintf(line, sizeof line, "Unit %lu", (unsigned long)_group.unit);
    _display->drawTextLeftAlign(0, 40, line);
  }

  if (s.mains == PowerMonitor::Mains::off && !_buttons.counting()) {
    // "?" when the cut is the battery's trend, not the mains wire (section 10).
    const char* cut = s.mainsEstimated ? "Power cut?" : "Power cut";
    if (s.hoursLeft) {
      snprintf(line, sizeof line, "%s about %lu h", cut, (unsigned long)s.hoursLeft);
    } else {
      snprintf(line, sizeof line, "%s", cut);
    }
    _display->drawTextLeftAlign(0, _display->height() - 10, line);
  }
  _display->endFrame();
}
