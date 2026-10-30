#include <cstring>

#include "../core/provision.hpp"
#include "test.hpp"

using namespace helpandi;

namespace {

GroupSettings sample() {
    GroupSettings g{};
    for (int i = 0; i < 16; i++) g.groupID[i] = uint8_t(i);
    g.member = 9;
    g.unit = 70009;
    g.okClosesCall = true;
    g.reportPowerCut = true;
    g.antenna = Antenna::external3dBi;
    for (int i = 0; i < 32; i++) g.respondersKey[i] = uint8_t(0x80 + i);
    for (int i = 0; i < 16; i++) g.channelSecret[i] = uint8_t(0x40 + i);
    g.firstCoordinator = 1;
    return g;
}

MemberList sampleMembers(size_t n) {
    MemberList l;
    l.version = 5;
    for (size_t i = 0; i < n; i++) {
        l.members[i].number = uint16_t(i + 1);
        l.members[i].role = i == 0 ? Role::coordinator : i % 2 ? Role::responder : Role::caller;
        std::memset(l.members[i].signingKey, int(i + 1), 32);
    }
    l.count = n;
    return l;
}

}  // namespace

TEST(setGroupIsNinetyFiveBytesLaidOutAsDocumented) {
    uint8_t out[kSetGroupBytes];
    GroupSettings g = sample();
    CHECK(writeSetGroup(g, out, sizeof out) == 95);
    CHECK(out[0] == 0x71);
    CHECK(out[1] == 0 && out[16] == 15);
    CHECK(out[17] == 9 && out[18] == 0);
    CHECK(out[19] == 0x79 && out[20] == 0x11 && out[21] == 0x01 && out[22] == 0x00);  // 70009
    CHECK(out[23] == 5);                                                                // closes, reports
    CHECK(out[24] == 2);
    CHECK(out[25] == 0x80 && out[56] == 0x9F);
    CHECK(out[57] == 0x40 && out[72] == 0x4F);
    CHECK(out[73] == 0 && out[88] == 0);
    CHECK(out[93] == 1 && out[94] == 0);
    GroupSettings back{};
    CHECK(parseSetGroup(out, sizeof out, back));
    CHECK(std::memcmp(&back, &g, sizeof g) == 0);
    CHECK(back.hasRespondersKey() && !back.hasOldSecret());
    CHECK(writeSetGroup(g, out, 94) == 0);
}

TEST(setGroupRefusesTheWrongLengthAnEmptySecretOrAnUnknownAntenna) {
    uint8_t out[kSetGroupBytes];
    GroupSettings g = sample(), back{};
    writeSetGroup(g, out, sizeof out);
    CHECK(!parseSetGroup(out, 94, back));
    out[24] = 4;
    CHECK(!parseSetGroup(out, 95, back));
    out[24] = 0;
    std::memset(out + 57, 0, 16);
    CHECK(!parseSetGroup(out, 95, back));
}

TEST(membersArriveInChunksOfFourAndReplaceTheListWhenWhole) {
    MemberList l = sampleMembers(9), built;
    built = sampleMembers(2);
    uint8_t chunk[7 + 4 * kMemberBytes];
    bool complete = false;
    for (size_t i = 0; i < 9; i += 4) {
        size_t n = writeMembersChunk(l, i, chunk, sizeof chunk);
        CHECK(n == 7 + (i == 8 ? 1 : 4) * kMemberBytes);
        CHECK(chunk[0] == 0x72 && chunk[1] == 5 && chunk[5] == i && chunk[6] == 9);
        CHECK(parseMembersChunk(chunk, n, built, complete));
        CHECK(complete == (i == 8));
    }
    CHECK(built.count == 9 && built.version == 5);
    for (size_t i = 0; i < 9; i++) {
        CHECK(built.members[i].number == l.members[i].number && built.members[i].role == l.members[i].role);
        CHECK(std::memcmp(built.members[i].signingKey, l.members[i].signingKey, 32) == 0);
    }
    CHECK(chunk[7] == 9 && chunk[8] == 0 && chunk[9] == 1 && chunk[10] == 9);
}

TEST(aChunkOutOfOrderOrWithABadRoleIsRefused) {
    MemberList l = sampleMembers(5), built;
    uint8_t chunk[7 + 4 * kMemberBytes];
    bool complete;
    size_t n = writeMembersChunk(l, 4, chunk, sizeof chunk);
    CHECK(!parseMembersChunk(chunk, n, built, complete));
    n = writeMembersChunk(l, 0, chunk, sizeof chunk);
    CHECK(parseMembersChunk(chunk, n, built, complete) && !complete);
    chunk[1] = 6;
    n = writeMembersChunk(l, 4, chunk, sizeof chunk);
    chunk[1] = 6;
    CHECK(!parseMembersChunk(chunk, n, built, complete));
    n = writeMembersChunk(l, 4, chunk, sizeof chunk);
    chunk[9] = 0;
    CHECK(!parseMembersChunk(chunk, n, built, complete));
    CHECK(!parseMembersChunk(chunk, n - 1, built, complete));
    CHECK(writeMembersChunk(l, 6, chunk, sizeof chunk) == 0);
}

TEST(aRemovalCountsOnlyWithANewerVersion) {
    MemberList l = sampleMembers(3);
    CHECK(!l.remove(2, 5));
    CHECK(l.find(2) != nullptr);
    CHECK(l.remove(2, 6));
    CHECK(l.find(2) == nullptr && l.count == 2 && l.version == 6);
    CHECK(!l.remove(7, 7));
    CHECK(l.version == 7);
}

TEST(routeResultIsRequestAndOneByte) {
    const uint8_t sent[] = {0x74, 0x0C, 0x00, 0x01}, failed[] = {0x74, 0x0C, 0x00, 0x00}, bad[] = {0x74, 0x0C, 0x00, 0x02};
    RouteResult r{};
    CHECK(parseRouteResult(sent, 4, r) && r.request == 12 && r.sent);
    CHECK(parseRouteResult(failed, 4, r) && !r.sent);
    CHECK(!parseRouteResult(bad, 4, r));
    CHECK(!parseRouteResult(sent, 3, r));
}

TEST(antennaGainsAreTheOnesThePowerCapUses) {
    CHECK(antennaGainDBi(Antenna::whip) == 2.0);
    CHECK(antennaGainDBi(Antenna::stub) == 0.0);
    CHECK(antennaGainDBi(Antenna::external3dBi) == 3.0);
    CHECK(antennaGainDBi(Antenna::external5dBi) == 5.0);
}
