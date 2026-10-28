import CryptoKit
import Foundation

/// What a caller types and where they are, sealed once for every responder in the group
/// (decision 12) and sent as one message on the group channel or the internet, instead of a copy
/// to each responder.
///
/// The key comes from the caller's own key and the responders' public key, so nothing extra goes
/// on air for it: only the unit, request and part in the clear (as in every frame), five random
/// bytes that finish the nonce, and the 16-byte tag.
public enum ForResponders {
    static let label = Data("HELPA-RESPONDERS-1".utf8)

    /// `frame` must be a note or a position from `me`, the caller.
    public static func seal(_ frame: HelpFrame, from me: DeviceIdentity, in group: GroupState) -> HelpFrame? {
        guard let (unit, request, part) = frame.personalPart, let responders = group.secrets.responderPublicKey,
              let key = try? key(mine: me.privateKey, theirs: responders, group: group.secrets.groupID) else { return nil }
        let salt = randomBytes(5)
        guard let box = try? ChaChaPoly.seal(frame.encoded(), using: key, nonce: nonce(unit, request, part, salt),
                                             authenticating: group.secrets.groupID) else { return nil }
        return .forResponders(unit: unit, request: request, part: part, sealed: salt + box.ciphertext + box.tag)
    }

    /// On a responder's phone: the note or position inside, if it opens and names the same unit,
    /// request and part as its outside. During a changeover after a removal, the old key is tried.
    public static func open(_ frame: HelpFrame, in group: GroupState) -> HelpFrame? {
        guard case let .forResponders(unit, request, part, sealed) = frame, sealed.count > 21,
              let caller = group.member(unit: unit) else { return nil }
        let salt = sealed.prefix(5), body = sealed.dropFirst(5)
        for secrets in [group.secrets, group.previousSecrets].compactMap({ $0 }) {
            guard let mine = secrets.responderPrivateKey.flatMap({ try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }),
                  let key = try? key(mine: mine, theirs: caller.publicKey, group: group.secrets.groupID),
                  let box = try? ChaChaPoly.SealedBox(nonce: nonce(unit, request, part, Data(salt)), ciphertext: body.dropLast(16), tag: body.suffix(16)),
                  let plain = try? ChaChaPoly.open(box, using: key, authenticating: group.secrets.groupID),
                  let inner = HelpFrame(plain), let (u, r, p) = inner.personalPart, u == unit, r == request, p == part else { continue }
            return inner
        }
        return nil
    }

    private static func key(mine: Curve25519.KeyAgreement.PrivateKey, theirs: Data, group: Data) throws -> SymmetricKey {
        let shared = try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: group, sharedInfo: label, outputByteCount: 32)
    }

    private static func nonce(_ unit: UInt32, _ request: UInt16, _ part: UInt8, _ salt: Data) throws -> ChaChaPoly.Nonce {
        var d = Data()
        withUnsafeBytes(of: unit.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: request.bigEndian) { d.append(contentsOf: $0) }
        d.append(part)
        return try ChaChaPoly.Nonce(data: d + salt)
    }
}
