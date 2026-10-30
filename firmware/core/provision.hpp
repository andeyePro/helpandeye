// What the phone gives the box over the Bluetooth companion link, as Help&I commands in a range
// MeshCore's companion protocol does not use (firmware/DESIGN.md, section 6), and what the box
// tells the phone. The same bytes are what the box keeps in flash, so one parser serves both.
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

namespace helpandi {

// App to box. MeshCore's commands stop at 66 and its pushes start at 0x80.
constexpr uint8_t kCmdInfo = 0x70;
constexpr uint8_t kCmdSetGroup = 0x71;
constexpr uint8_t kCmdSetMembers = 0x72;
constexpr uint8_t kCmdGetCalls = 0x73;
constexpr uint8_t kCmdRouteResult = 0x74;
constexpr uint8_t kCmdForget = 0x75;
// Box to app.
constexpr uint8_t kRespInfo = 0xA0;
constexpr uint8_t kRespCall = 0xA1;
constexpr uint8_t kRespEndOfCalls = 0xA2;
// A frame the box made (a call, a signed call state, a sealed report), for the phone to carry on
// its own routes.
constexpr uint8_t kPushFrame = 0xA3;
// MeshCore's own reply codes, which the app already reads.
constexpr uint8_t kRespOK = 0;
constexpr uint8_t kRespError = 1;
constexpr uint8_t kErrorBadArgument = 6;

constexpr uint8_t kHelpandiProtocol = 1;
constexpr size_t kGroupIDBytes = 16;
constexpr size_t kChannelSecretBytes = 16;
constexpr size_t kKeyBytes = 32;
constexpr size_t kMaxMembers = 32;

enum class Role : uint8_t { caller = 1, responder = 2, both = 3, coordinator = 4 };

inline bool canRespond(Role r) { return r != Role::caller; }

enum class Antenna : uint8_t { whip = 0, stub = 1, external3dBi = 2, external5dBi = 3 };

// The gain the power cap allows for (section 8): the V4's standard whip until measured.
double antennaGainDBi(Antenna a);

struct GroupSettings {
    uint8_t groupID[kGroupIDBytes];
    uint16_t member;
    uint32_t unit;
    bool okClosesCall;
    bool callerMayClose;
    bool reportPowerCut;
    Antenna antenna;
    // All zero when the group has no responders' key yet: then nothing personal is sent.
    uint8_t respondersKey[kKeyBytes];
    uint8_t channelSecret[kChannelSecretBytes];
    // All zero outside a changeover.
    uint8_t oldChannelSecret[kChannelSecretBytes];
    uint32_t oldSecretEndsAt;
    uint16_t firstCoordinator;

    bool hasRespondersKey() const;
    bool hasOldSecret() const;
};

constexpr size_t kSetGroupBytes = 95;

// The body of kCmdSetGroup, command byte included. Returns false for the wrong length.
bool parseSetGroup(const uint8_t* data, size_t length, GroupSettings& out);
size_t writeSetGroup(const GroupSettings& g, uint8_t* out, size_t cap);

struct Member {
    uint16_t number;
    Role role;
    uint8_t signingKey[kKeyBytes];
};

struct MemberList {
    Member members[kMaxMembers];
    size_t count = 0;
    uint32_t version = 0;

    const Member* find(uint16_t number) const;
    // A removal signed by the first coordinator (section 6). Ignored unless `version` is newer.
    bool remove(uint16_t number, uint32_t version);
};

constexpr size_t kMemberBytes = 35;
constexpr size_t kMembersPerChunk = 4;

// kCmdSetMembers comes in chunks: version u32, index u8 (the first member's position), total u8,
// then up to four members of number u16, role u8 and signing key. Index 0 starts a new list,
// which replaces the old one once every position up to `total` has arrived. Returns false for a
// malformed chunk; `complete` is set when the list is whole.
bool parseMembersChunk(const uint8_t* data, size_t length, MemberList& building, bool& complete);
// Writes chunk `index` of the list (the members from index onwards, up to four), for the phone
// side and for the tests.
size_t writeMembersChunk(const MemberList& list, size_t index, uint8_t* out, size_t cap);

struct RouteResult {
    uint16_t request;
    bool sent;
};

bool parseRouteResult(const uint8_t* data, size_t length, RouteResult& out);

}  // namespace helpandi
