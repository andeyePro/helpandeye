import CryptoKit
import Foundation

/// What a caller types and where they are, and a coordinator's reason for closing a call, sealed
/// once for every responder in the group (decision 12) and sent as one message on the group
/// channel or the internet, instead of a copy to each responder.
///
/// The key comes from the sender's own key and the responders' public key, so no key goes on
/// air: only the unit, request and part in the clear (as in every frame), five random bytes that
/// finish the nonce, and the 16-byte tag. Inside, the sender signs it, because every responder can
/// work out that key and so could otherwise write as the sender.
public enum ForResponders {
    static let label = Data("HELPA-RESPONDERS-1".utf8)
    /// The longest piece of typed text one sealed, signed note carries and still fits one
    /// 165-byte MeshCore channel datagram; longer text goes as several notes.
    public static let maxNoteBytes = 56

    /// `frame` must be a note, position or choice from `me`, member `signer`, the caller, or a
    /// close with its reason from `me`, a coordinator. Sealed with the current responders' key
    /// only, never the old one kept during a changeover: a removed responder still holds that, so
    /// a responder who has not scanned their update sees the call but not what was typed until
    /// they do.
    public static func seal(_ frame: HelpFrame, from me: DeviceIdentity, as signer: UInt16, in group: GroupState, at now: Date) -> [HelpFrame] {
        guard let (unit, request, part) = frame.forRespondersPart else { return [] }
        let signed = HelpFrame.signing(frame, as: signer, identity: me, group: group.secrets.groupID).encoded()
        return [group.secrets].compactMap { secrets in
            guard let responders = secrets.responderPublicKey,
                  let key = try? key(mine: me.privateKey, theirs: responders, group: group.secrets.groupID) else { return nil }
            let salt = randomBytes(5)
            guard let box = try? ChaChaPoly.seal(signed, using: key, nonce: nonce(unit, request, part, salt),
                                                 authenticating: group.secrets.groupID) else { return nil }
            return .forResponders(unit: unit, request: request, part: part, sealed: salt + box.ciphertext + box.tag)
        }
    }

    /// On a responder's phone: what is inside, if it opens with a responders' key in use, is signed
    /// by its sender, and names the same unit, request and part as its outside. A note, position
    /// or choice comes back plain, and only from the member whose unit it names; a close with its
    /// reason comes back still in its coordinator's signature, so the rules for who may close
    /// apply to it as to a plain one. The sender is not named outside, so the key is tried for
    /// the unit's member and for each coordinator.
    public static func open(_ frame: HelpFrame, in group: GroupState, at now: Date) -> HelpFrame? {
        guard case let .forResponders(unit, request, part, sealed) = frame, sealed.count > 21 else { return nil }
        let salt = sealed.prefix(5), body = sealed.dropFirst(5)
        let senders = [group.member(unit: unit)].compactMap { $0 } + group.members.filter { $0.role == .coordinator && $0.unit != unit }
        for secrets in group.listening(at: now) {
            guard let mine = secrets.responderPrivateKey.flatMap({ try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }) else { continue }
            for sender in senders {
                guard let key = try? key(mine: mine, theirs: sender.publicKey, group: group.secrets.groupID),
                      let box = try? ChaChaPoly.SealedBox(nonce: nonce(unit, request, part, Data(salt)), ciphertext: body.dropLast(16), tag: body.suffix(16)),
                      let plain = try? ChaChaPoly.open(box, using: key, authenticating: group.secrets.groupID),
                      let signed = HelpFrame(plain), case let .signed(signer, _, _) = signed, signer == sender.number,
                      let inner = signed.verifiedInner(signedBy: sender.signingKey, group: group.secrets.groupID),
                      let (u, r, p) = inner.forRespondersPart, u == unit, r == request, p == part else { continue }
                if case .callState = inner { return sender.role == .coordinator ? signed : nil }
                return sender.unit == unit ? inner : nil
            }
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
