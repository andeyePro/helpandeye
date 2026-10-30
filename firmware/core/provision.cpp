#include "provision.hpp"

#include <cstdio>
#include <cstring>

#include "frame.hpp"

namespace helpandi {

namespace {

bool allZero(const uint8_t* p, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (p[i]) return false;
    return true;
}

uint16_t readU16(const uint8_t* p) { return uint16_t(p[0] | p[1] << 8); }
uint32_t readU32(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
void writeU16(uint8_t* p, uint16_t v) {
    p[0] = uint8_t(v);
    p[1] = uint8_t(v >> 8);
}
void writeU32(uint8_t* p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = uint8_t(v >> (8 * i));
}

bool validRole(uint8_t r) { return r >= 1 && r <= 4; }

}  // namespace

double antennaGainDBi(Antenna a) {
    switch (a) {
    case Antenna::whip: return 2.0;
    case Antenna::stub: return 0.0;
    case Antenna::external3dBi: return 3.0;
    case Antenna::external5dBi: return 5.0;
    }
    return 2.0;
}

bool GroupSettings::hasRespondersKey() const { return !allZero(respondersKey, kKeyBytes); }
bool GroupSettings::hasOldSecret() const { return !allZero(oldChannelSecret, kChannelSecretBytes); }

bool parseSetGroup(const uint8_t* d, size_t length, GroupSettings& g) {
    if (length != kSetGroupBytes || d[0] != kCmdSetGroup || d[24] > uint8_t(Antenna::external5dBi)) return false;
    std::memcpy(g.groupID, d + 1, kGroupIDBytes);
    g.member = readU16(d + 17);
    g.unit = readU32(d + 19);
    g.okClosesCall = d[23] & 1;
    g.callerMayClose = d[23] & 2;
    g.reportPowerCut = d[23] & 4;
    g.antenna = Antenna(d[24]);
    std::memcpy(g.respondersKey, d + 25, kKeyBytes);
    std::memcpy(g.channelSecret, d + 57, kChannelSecretBytes);
    std::memcpy(g.oldChannelSecret, d + 73, kChannelSecretBytes);
    g.oldSecretEndsAt = readU32(d + 89);
    g.firstCoordinator = readU16(d + 93);
    return !allZero(g.channelSecret, kChannelSecretBytes) && !allZero(g.groupID, kGroupIDBytes);
}

size_t writeSetGroup(const GroupSettings& g, uint8_t* out, size_t cap) {
    if (cap < kSetGroupBytes) return 0;
    out[0] = kCmdSetGroup;
    std::memcpy(out + 1, g.groupID, kGroupIDBytes);
    writeU16(out + 17, g.member);
    writeU32(out + 19, g.unit);
    out[23] = uint8_t((g.okClosesCall ? 1 : 0) | (g.callerMayClose ? 2 : 0) | (g.reportPowerCut ? 4 : 0));
    out[24] = uint8_t(g.antenna);
    std::memcpy(out + 25, g.respondersKey, kKeyBytes);
    std::memcpy(out + 57, g.channelSecret, kChannelSecretBytes);
    std::memcpy(out + 73, g.oldChannelSecret, kChannelSecretBytes);
    writeU32(out + 89, g.oldSecretEndsAt);
    writeU16(out + 93, g.firstCoordinator);
    return kSetGroupBytes;
}

const Member* MemberList::find(uint16_t number) const {
    for (size_t i = 0; i < count; i++)
        if (members[i].number == number) return &members[i];
    return nullptr;
}

bool MemberList::remove(uint16_t number, uint32_t newVersion) {
    if (newVersion <= version) return false;
    version = newVersion;
    for (size_t i = 0; i < count; i++) {
        if (members[i].number != number) continue;
        members[i] = members[--count];
        return true;
    }
    return false;
}

bool parseMembersChunk(const uint8_t* d, size_t length, MemberList& building, bool& complete) {
    complete = false;
    if (length < 7 || d[0] != kCmdSetMembers || (length - 7) % kMemberBytes) return false;
    uint32_t version = readU32(d + 1);
    size_t index = d[5], total = d[6], n = (length - 7) / kMemberBytes;
    if (total > kMaxMembers || n > kMembersPerChunk || index + n > total) return false;
    if (index == 0) {
        building.count = 0;
        building.version = version;
    } else if (index != building.count || version != building.version) {
        return false;
    }
    for (size_t i = 0; i < n; i++) {
        const uint8_t* m = d + 7 + i * kMemberBytes;
        if (!validRole(m[2])) return false;
        Member& out = building.members[building.count + i];
        out.number = readU16(m);
        out.role = Role(m[2]);
        std::memcpy(out.signingKey, m + 3, kKeyBytes);
    }
    building.count += n;
    complete = building.count == total;
    return true;
}

size_t writeMembersChunk(const MemberList& list, size_t index, uint8_t* out, size_t cap) {
    size_t n = list.count - index < kMembersPerChunk ? list.count - index : kMembersPerChunk;
    size_t need = 7 + n * kMemberBytes;
    if (index > list.count || cap < need) return 0;
    out[0] = kCmdSetMembers;
    writeU32(out + 1, list.version);
    out[5] = uint8_t(index);
    out[6] = uint8_t(list.count);
    for (size_t i = 0; i < n; i++) {
        const Member& m = list.members[index + i];
        uint8_t* p = out + 7 + i * kMemberBytes;
        writeU16(p, m.number);
        p[2] = uint8_t(m.role);
        std::memcpy(p + 3, m.signingKey, kKeyBytes);
    }
    return need;
}

const char* NameList::find(uint16_t member) const {
    for (size_t i = 0; i < count; i++)
        if (names[i].member == member) return reinterpret_cast<const char*>(names[i].text);
    return nullptr;
}

bool parseNamesChunk(const uint8_t* d, size_t length, NameList& building, bool& complete) {
    complete = false;
    if (length < 7 || d[0] != kCmdSetNames) return false;
    uint32_t version = readU32(d + 1);
    size_t index = d[5], total = d[6];
    if (total > kMaxMembers || index > total) return false;
    if (index == 0) {
        building.count = 0;
        building.version = version;
    } else if (index != building.count || version != building.version) {
        return false;
    }
    size_t at = 7, n = 0;
    while (at < length) {
        if (n == kNamesPerChunk || index + n == total || at + 3 > length) return false;
        size_t len = d[at + 2];
        if (len < 1 || len > kMaxNameBytes || at + 3 + len > length || !isValidUTF8(d + at + 3, len)) return false;
        Name& out = building.names[building.count + n];
        out.member = readU16(d + at);
        out.length = uint8_t(len);
        std::memcpy(out.text, d + at + 3, len);
        out.text[len] = 0;
        at += 3 + len;
        n++;
    }
    building.count += n;
    complete = building.count == total;
    return true;
}

size_t writeNamesChunk(const NameList& list, size_t index, uint8_t* out, size_t cap) {
    if (index > list.count || cap < 7) return 0;
    size_t n = list.count - index < kNamesPerChunk ? list.count - index : kNamesPerChunk;
    size_t need = 7;
    for (size_t i = 0; i < n; i++) need += 3 + list.names[index + i].length;
    if (cap < need) return 0;
    out[0] = kCmdSetNames;
    writeU32(out + 1, list.version);
    out[5] = uint8_t(index);
    out[6] = uint8_t(list.count);
    uint8_t* p = out + 7;
    for (size_t i = 0; i < n; i++) {
        const Name& name = list.names[index + i];
        writeU16(p, name.member);
        p[2] = name.length;
        std::memcpy(p + 3, name.text, name.length);
        p += 3 + name.length;
    }
    return need;
}

size_t seenByWords(const char* name, char* out, size_t cap) {
    bool printable = name && *name;
    for (const char* c = name; printable && *c; c++)
        if (*c < 0x20 || *c > 0x7E) printable = false;
    int n = std::snprintf(out, cap, "%s has seen your call.", printable ? name : "A responder");
    return n < 0 || size_t(n) >= cap ? 0 : size_t(n);
}

bool parseRouteResult(const uint8_t* d, size_t length, RouteResult& out) {
    if (length != 4 || d[0] != kCmdRouteResult || d[3] > 1) return false;
    out.request = readU16(d + 1);
    out.sent = d[3] == 1;
    return true;
}

}  // namespace helpandi
