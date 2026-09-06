/*
 * The body of a one-to-one message: sealed (`x:`) or plain (`m:`).
 *
 * docs/XPRS.md section 9.2 is the whole mechanism, and it is four sentences:
 *
 *   `x:` carries the sealed body and replaces `m:`.
 *   t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 x:pQ4m9xT2vB8kR sig:<60>
 *   `t:`, `f:`, `d:` and `ts:` stay in cleartext, so an intermediate station can
 *   route the packet, identify the recipient and release a carried copy on the
 *   matching receipt, without reading the content.
 *
 * Two consequences the rest of this file exists to honour.
 *
 * **There is no privacy flag, and there must not be one.** The wire form IS the
 * statement: a packet carrying `x:` is private, one carrying `m:` is plain, and
 * nothing else distinguishes them. Design rule 6 (section 2) is why -- "Nothing
 * is defined out of band. No receiver requires prior state to read a packet."
 * So either side may switch on any single message, mid-conversation, with no
 * negotiation, no handshake and no remembered mode. That behaviour is not built
 * here; it falls out of the format, and the job of this file is to not get in
 * its way by inventing state.
 *
 * **Private is the default for a direct message** (section 9.4: encryption is
 * "permitted, and is the default for direct messages" on licence-free spectrum
 * and the internet) -- and is forbidden outright on amateur bands, which is the
 * one place a bearer changes the answer. See [XprsBandRule].
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';

import '../../util/nostr_crypto.dart';
import '../../util/xprs_crypto.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';

/// Which form a body took ON THE WIRE. Read from the packet, never carried in
/// it and never remembered between packets.
enum XprsPrivacy {
  /// `x:` -- ciphertext to everyone but the recipient (section 9.2).
  sealed,

  /// `m:` -- readable by every station that hears it (section 6.2).
  plain,
}

/// Why a body could not be produced in the form that was asked for.
///
/// A refusal is always reported and NEVER silently downgraded. Section 36.8 is
/// what makes that a correctness rule rather than a nicety: "Sealed mail travels
/// on the strength of the seal ... Clear mail is released only to a declared
/// holder or fetched by the recipient itself. **Plaintext is disclosure.**" The
/// two forms are handled differently by every carrier that touches them, so a
/// message that quietly became plain is not a slightly-weaker message, it is a
/// message under different release rules than its author chose.
enum XprsSealRefusal {
  /// No usable public key for the recipient. Their `t:identity` (section 9.3)
  /// has not been heard, or what was heard did not decode.
  noRecipientKey,

  /// This station has no private key to seal with.
  noOwnKey,

  /// The cipher failed.
  cipherFailed,

  /// Section 9.4: "An implementation able to reach amateur infrastructure must
  /// refuse to transmit a sealed body onto it."
  amateurBand,

  /// The sealed body does not fit and splitting was not offered.
  tooLong,
}

/// A body that was built, or the reason it was not.
class XprsBodyResult {
  const XprsBodyResult.ok(this.packets, this.privacy, {this.rejoined})
      : refusal = null;
  const XprsBodyResult.refused(this.refusal)
      : packets = const [],
        privacy = XprsPrivacy.sealed,
        rejoined = null;

  /// The wires to air, in order. More than one when the body was split
  /// (section 6.6).
  final List<XprsPacket> packets;

  /// The form actually produced -- what the label must report, as against what
  /// the caller asked for.
  final XprsPrivacy privacy;

  final XprsSealRefusal? refusal;

  /// The packet the parts reassemble into (joined `m:`/`x:`, no `n:`) when the
  /// body was split, null when it was not.
  ///
  /// The §5 identifier of THAT is what the receiver derives and what a receipt
  /// names in `r:`. A caller keying a bubble on `packets.first` would key it on
  /// part one of nine, which no receipt will ever mention.
  final XprsPacket? rejoined;

  /// The packet whose identifier names this message, split or not.
  XprsPacket? get identityPacket =>
      rejoined ?? (packets.isEmpty ? null : packets.first);

  bool get ok => refusal == null;
}

/// Whether this station can currently reach amateur spectrum.
///
/// Section 9.4 forbids `x:` there ("Sealing a body obscures meaning, which is
/// the prohibited act", 9.4.3). No bearer this station owns is amateur spectrum
/// today -- Bluetooth and LoRa ISM, WiFi and the internet are all licence-free,
/// where section 9.4's table says encryption is permitted and is the default.
/// The hook exists so the rule lives in the one place that decides the body,
/// rather than being remembered later by whoever adds an HF bearer.
class XprsBandRule {
  static bool Function() reachesAmateurSpectrum = () => false;
}

/// The 16-byte IV and the AES block padding a sealed body pays over its text.
const int _sealOverhead = 16 + 16;

/// Build the one-to-one message [text] as [private] asks, split per section 6.6
/// when it does not fit.
///
/// [head] is the packet up to but excluding the body: `t:message f:.. d:.. ts:..`
/// plus any envelope field the caller wants repeated on every part. Section 6.6:
/// "Every field except `m:` and `n:` is repeated on each part".
///
/// [recipientKeyHex] is the recipient's 32-byte x-only public key as hex -- what
/// `NostrCrypto.decodeNpub` returns for the `k:` of their `t:identity`.
XprsBodyResult xprsBuildDirect({
  required XprsPacket head,
  required String text,
  required bool private,
  String? recipientKeyHex,
  BigInt? signingKey,
}) {
  if (!private) {
    return _plain(head, text, signingKey ?? xprsProfileScalar());
  }
  if (XprsBandRule.reachesAmateurSpectrum()) {
    return const XprsBodyResult.refused(XprsSealRefusal.amateurBand);
  }
  final d = signingKey ?? xprsProfileScalar();
  if (d == null) return const XprsBodyResult.refused(XprsSealRefusal.noOwnKey);
  final pub = _pubBytes(recipientKeyHex);
  if (pub == null) {
    return const XprsBodyResult.refused(XprsSealRefusal.noRecipientKey);
  }
  return _sealed(head, text, d, pub);
}

Uint8List? _pubBytes(String? hexOrNpub) {
  final s = (hexOrNpub ?? '').trim();
  if (s.isEmpty) return null;
  try {
    final hex = s.startsWith('npub') ? NostrCrypto.decodeNpub(s) : s;
    if (hex.length != 64) return null;
    return Uint8List.fromList(HEX.decode(hex));
  } catch (_) {
    return null;
  }
}

XprsBodyResult _plain(XprsPacket head, String text, BigInt? d) {
  final whole = head.with_('m', text);
  final signed = d != null ? xprsSign(whole, d) : whole;
  if (signed.fits) {
    return XprsBodyResult.ok([signed], XprsPrivacy.plain);
  }
  final probe = head.with_('n', '9/9').with_('sig', 'x' * 60).with_('m', '');
  final chunks = xprsChunkAtSpaces(text, XprsPacket.maxBytes - probe.byteLength);
  if (chunks.isEmpty || chunks.length > 9) {
    return const XprsBodyResult.refused(XprsSealRefusal.tooLong);
  }
  // Section 9.1.1: "split it (section 6.6) and sign the last part". The
  // signature covers the packet the parts reassemble into -- joined `m:`, no
  // `n:` -- which is also what section 6.6 derives the identifier from.
  final joined = head.with_('m', chunks.join(' '));
  final sig = d != null ? xprsSign(joined, d)['sig'] : null;
  final out = <XprsPacket>[];
  for (var i = 0; i < chunks.length; i++) {
    var p = head.with_('n', '${i + 1}/${chunks.length}').with_('m', chunks[i]);
    if (i == chunks.length - 1 && sig != null) p = p.with_('sig', sig);
    out.add(p);
  }
  return XprsBodyResult.ok(out, XprsPrivacy.plain, rejoined: joined);
}

XprsBodyResult _sealed(
    XprsPacket head, String text, BigInt d, Uint8List pub) {
  String? seal(String clear) {
    final blob = XprsCrypto.encryptFor(d, pub, Uint8List.fromList(utf8.encode(clear)));
    if (blob == null) return null;
    return base64Url.encode(blob).replaceAll('=', '');
  }

  final one = seal(text);
  if (one == null) {
    return const XprsBodyResult.refused(XprsSealRefusal.cipherFailed);
  }
  final whole = xprsSign(head.with_('x', one), d);
  if (whole.fits) {
    return XprsBodyResult.ok([whole], XprsPrivacy.sealed);
  }

  // Too long for one packet, so split (section 13.6: "A sealed body is longer
  // than the text it replaces, so a long carried message is split into parts
  // (section 6.6)").
  //
  // EACH PART IS SEALED SEPARATELY, so each carries its own `x:` and decrypts
  // on its own. Section 6.6 splits at spaces and joins with one space, and that
  // is done to the PLAINTEXT here -- the ciphertext has no spaces to split at
  // and joining halves of one AES stream would decrypt to nothing.
  //
  // Every part is signed, rather than only the last as section 9.1.1 allows.
  // 9.1.1 is an economy for when the signature is what does not fit; sealing
  // per part leaves room for one each, so the section 9.1 default -- "a station
  // signs by default" -- applies, and every part stays verifiable on its own by
  // any station that hears it.
  final probe = head
      .with_('n', '9/9')
      .with_('sig', 'x' * 60)
      .with_('x', 'x' * _b64Len(_sealOverhead));
  final room = XprsPacket.maxBytes - probe.byteLength;
  // Undo base64's 4/3 expansion to get the plaintext each part may carry.
  final capacity = (room * 3) ~/ 4;
  if (capacity <= 0) {
    return const XprsBodyResult.refused(XprsSealRefusal.tooLong);
  }
  final chunks = xprsChunkAtSpaces(text, capacity);
  if (chunks.isEmpty || chunks.length > 9) {
    return const XprsBodyResult.refused(XprsSealRefusal.tooLong);
  }
  final out = <XprsPacket>[];
  for (var i = 0; i < chunks.length; i++) {
    final blob = seal(chunks[i]);
    if (blob == null) {
      return const XprsBodyResult.refused(XprsSealRefusal.cipherFailed);
    }
    final p = xprsSign(
        head.with_('n', '${i + 1}/${chunks.length}').with_('x', blob), d);
    if (!p.fits) return const XprsBodyResult.refused(XprsSealRefusal.tooLong);
    out.add(p);
  }
  // What the RECEIVER ends up with, and it is NOT the ciphertexts joined.
  //
  // XprsPartTable opens each part's `x:` as it arrives and joins the
  // PLAINTEXT, then builds `first.without({n, sig, x, m}).with_('m', joined)`.
  // So the packet whose §5 identifier names this message carries `m:` even
  // though every part carried `x:` — and a sender that derived its id from the
  // ciphertext would key its bubble on a value no receipt will ever mention.
  //
  // §6.6 joins with exactly one space, so the sender must join the same way
  // rather than reuse the original text: a body with a double space between
  // two words reassembles with one.
  final joined = head.with_('m', chunks.join(' '));
  return XprsBodyResult.ok(out, XprsPrivacy.sealed, rejoined: joined);
}

int _b64Len(int bytes) => ((bytes + 2) ~/ 3) * 4;

/// Split [text] into pieces of at most [capacity] BYTES, at spaces only.
///
/// Section 6.6: "A sender splits only at a space, and never inside a word." A
/// word longer than a whole part has no space to split at, so it is hard-cut --
/// losing a monster URL's tail is better than losing everything after it.
///
/// Extracted from `XprsPublisher._wires` so the plain and sealed paths split
/// identically; there is one splitter in this codebase and this is it.
List<String> xprsChunkAtSpaces(String text, int capacity) {
  if (capacity <= 0) return const [];
  final chunks = <String>[];
  var current = StringBuffer();
  for (final word in text.split(' ')) {
    var w = word;
    while (utf8.encode(w).length > capacity) {
      // The budget is BYTES; `substring` counts UTF-16 units. Cutting by
      // units over-cut a word with emoji in it and could sever a surrogate
      // pair, leaving a lone surrogate in a part. Cut by bytes, backed off
      // to a code-point boundary (a UTF-8 continuation byte is 10xxxxxx).
      final b = utf8.encode(w);
      var cut = capacity;
      while (cut > 0 && (b[cut] & 0xC0) == 0x80) cut--;
      if (cut == 0) break; // a single code point wider than the part: keep it
      chunks.add(utf8.decode(b.sublist(0, cut)));
      w = utf8.decode(b.sublist(cut));
    }
    final trial = current.isEmpty ? w : '$current $w';
    if (utf8.encode(trial).length > capacity) {
      if (current.isNotEmpty) chunks.add(current.toString());
      current = StringBuffer(w);
    } else {
      current = StringBuffer(trial);
    }
  }
  if (current.isNotEmpty) chunks.add(current.toString());
  return chunks;
}

/// What form [p] arrived in, and its text where that can be read.
///
/// The privacy verdict is structural and always available: `x:` present means
/// sealed, `m:` present means plain. The TEXT of a sealed body needs the key,
/// so [clear] is null when this station cannot open it -- which is a fact worth
/// showing the reader, not a reason to drop the packet.
class XprsBody {
  const XprsBody(this.privacy, this.clear);
  final XprsPrivacy privacy;
  final String? clear;

  bool get readable => clear != null;
}

/// Read the body of [p], opening a sealed one with [ownKey] against the
/// sender's [senderKeyHex] when both are available.
///
/// A packet carrying BOTH `x:` and `m:` is read as sealed. Section 9.2 says
/// `x:` "replaces `m:`", so the two never legitimately coexist; preferring the
/// sealed field means a stripped-and-replaced body cannot be smuggled past a
/// reader by adding the field the spec says was removed.
XprsBody xprsReadBody(XprsPacket p,
    {BigInt? ownKey, String? senderKeyHex}) {
  final x = p['x'];
  if (x != null) {
    final d = ownKey ?? xprsProfileScalar();
    final pub = _pubBytes(senderKeyHex);
    if (d == null || pub == null) {
      return const XprsBody(XprsPrivacy.sealed, null);
    }
    final blob = _b64(x);
    if (blob == null) return const XprsBody(XprsPrivacy.sealed, null);
    final pt = XprsCrypto.decryptFrom(d, pub, blob);
    if (pt == null) return const XprsBody(XprsPrivacy.sealed, null);
    try {
      return XprsBody(XprsPrivacy.sealed, utf8.decode(pt));
    } catch (_) {
      return const XprsBody(XprsPrivacy.sealed, null);
    }
  }
  return XprsBody(XprsPrivacy.plain, p['m'] ?? '');
}

Uint8List? _b64(String v) {
  try {
    return base64Url.decode(v.padRight((v.length + 3) & ~3, '='));
  } catch (_) {
    return null;
  }
}
