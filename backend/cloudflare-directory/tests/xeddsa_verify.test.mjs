import assert from "node:assert/strict";
import fs from "node:fs";

const source = fs
  .readFileSync(new URL("../src/index.js", import.meta.url), "utf8")
  .replace(/\nexport default[\s\S]*$/, "")
  .replace(/export class DirectoryStore/g, "class DirectoryStore")
  + "\nreturn { verifySignalIdentitySignature };\n";

const factory = new Function(
  "crypto",
  "btoa",
  "atob",
  "TextEncoder",
  source,
);

const { verifySignalIdentitySignature } = factory(
  globalThis.crypto,
  globalThis.btoa,
  globalThis.atob,
  globalThis.TextEncoder,
);

/*
 * Signal curve25519-java XEdDSA fast-test vector.
 *
 * Private key:
 *   all zeroes except byte 8 = 189, then X25519-clamped.
 *
 * Message:
 *   200 zero bytes.
 *
 * Randomness:
 *   64 zero bytes.
 *
 * Expected signature:
 *   11c7f3e6c4df9e8a5150e1db3b30f92de3a3b3aa438656545fa7390f4bcc7bb
 *   26c431d9e90643e4f0eaa0e9c557766fa69ada576d63dcaf2ac326c11d0b977
 *
 * The identity key below is the Signal encoded Curve25519 public key:
 *   0x05 || little-endian Montgomery u-coordinate.
 */

const identityKey =
  "BVmV9GTp001cpWuZBbmjzDfEVrLY0xPtvPWEtwW1wElV";

const signature =
  "Ecfz5sTfnopRUOHbOzD5LeOjs6pDhlZUX6c5D0vMe7JsQx2ekGQ+Tw6qDpxVd2b6aa2ldtY9yvKsMmwR0Ll3Ag==";

const message = "\x00".repeat(200);

const valid = await verifySignalIdentitySignature({
  identityKey,
  message,
  signature,
});

assert.equal(valid, true, "valid XEd25519 signature must verify");

const tamperedMessage = "\x00".repeat(199) + "\x01";

const messageRejected = await verifySignalIdentitySignature({
  identityKey,
  message: tamperedMessage,
  signature,
});

assert.equal(
  messageRejected,
  false,
  "signature must fail when message changes",
);

const signatureBytes = Uint8Array.from(
  atob(signature),
  (character) => character.charCodeAt(0),
);

signatureBytes[0] ^= 0x01;

const tamperedSignature = btoa(
  String.fromCharCode(...signatureBytes),
);

const signatureRejected = await verifySignalIdentitySignature({
  identityKey,
  message,
  signature: tamperedSignature,
});

assert.equal(
  signatureRejected,
  false,
  "tampered signature must be rejected",
);

const invalidRBytes = Uint8Array.from(
  atob(signature),
  (character) => character.charCodeAt(0),
);

/*
 * The high bit is the Edwards sign bit and is valid.
 * Instead, construct an actually invalid y >= p.
 */
const CURVE25519_P =
  (1n << 255n) - 19n;

const invalidY = new Uint8Array(32);
let invalidYValue = CURVE25519_P;

for (let i = 0; i < 32; i++) {
  invalidY[i] = Number(invalidYValue & 0xffn);
  invalidYValue >>= 8n;
}

invalidY[31] &= 0x7f;
invalidRBytes.set(invalidY, 0);

const invalidRSignature = btoa(
  String.fromCharCode(...invalidRBytes),
);

const invalidRRejected = await verifySignalIdentitySignature({
  identityKey,
  message,
  signature: invalidRSignature,
});

assert.equal(
  invalidRRejected,
  false,
  "R.y outside the field must be rejected",
);

const invalidSBytes = Uint8Array.from(
  atob(signature),
  (character) => character.charCodeAt(0),
);

invalidSBytes.fill(0xff, 32);

const invalidSSignature = btoa(
  String.fromCharCode(...invalidSBytes),
);

const invalidSRejected = await verifySignalIdentitySignature({
  identityKey,
  message,
  signature: invalidSSignature,
});

assert.equal(
  invalidSRejected,
  false,
  "s with excess bits must be rejected",
);


// Generate a valid Ed25519 signature carrying signBit = 1.
const FIELD_P = (1n << 255n) - 19n;

function modP(value) {
  const result = value % FIELD_P;
  return result < 0n ? result + FIELD_P : result;
}

function powMod(base, exponent) {
  let result = 1n;
  base = modP(base);

  while (exponent > 0n) {
    if (exponent & 1n) result = modP(result * base);
    base = modP(base * base);
    exponent >>= 1n;
  }

  return result;
}

function littleEndianToBigInt(bytes) {
  let result = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8n) | BigInt(bytes[i]);
  }
  return result;
}

function bigIntToLittleEndian(value, length) {
  const result = new Uint8Array(length);
  for (let i = 0; i < length; i++) {
    result[i] = Number(value & 0xffn);
    value >>= 8n;
  }
  return result;
}

let keyPair;
let rawPublicKey;
let publicSignBit;

do {
  keyPair = await globalThis.crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  );

  rawPublicKey = new Uint8Array(
    await globalThis.crypto.subtle.exportKey("raw", keyPair.publicKey),
  );

  publicSignBit = rawPublicKey[31] >>> 7;
} while (publicSignBit !== 1);

const yBytes = rawPublicKey.slice();
yBytes[31] &= 0x7f;

const y = littleEndianToBigInt(yBytes);
const denominator = modP(1n - y);

assert.notEqual(denominator, 0n, "public-key conversion denominator");

const u = modP(
  (1n + y) * powMod(denominator, FIELD_P - 2n),
);

const identityKeyBytes = new Uint8Array(33);
identityKeyBytes[0] = 0x05;
identityKeyBytes.set(bigIntToLittleEndian(u, 32), 1);

const signBitOneMessage = "XEdDSA signBit=1 verification test";
const signBitOneMessageBytes = new TextEncoder().encode(
  signBitOneMessage,
);

const signBitOneSignatureBytes = new Uint8Array(
  await globalThis.crypto.subtle.sign(
    { name: "Ed25519" },
    keyPair.privateKey,
    signBitOneMessageBytes,
  ),
);

// Signal-compatible XEdDSA encoding stores the public-key sign bit
// in the most significant bit of signature byte 63.
signBitOneSignatureBytes[63] |= 0x80;

const signBitOneIdentityKey = btoa(
  String.fromCharCode(...identityKeyBytes),
);

const signBitOneSignature = btoa(
  String.fromCharCode(...signBitOneSignatureBytes),
);

const signBitOneValid = await verifySignalIdentitySignature({
  identityKey: signBitOneIdentityKey,
  message: signBitOneMessage,
  signature: signBitOneSignature,
});

assert.equal(
  signBitOneValid,
  true,
  "valid XEdDSA signature with signBit=1 must verify",
);

const wrongSignBitBytes = signBitOneSignatureBytes.slice();
wrongSignBitBytes[63] &= 0x7f;

const wrongSignBitValid = await verifySignalIdentitySignature({
  identityKey: signBitOneIdentityKey,
  message: signBitOneMessage,
  signature: btoa(String.fromCharCode(...wrongSignBitBytes)),
});

assert.equal(
  wrongSignBitValid,
  false,
  "signature with incorrect signBit must be rejected",
);

console.log("valid signature with signBit=1: PASS");
console.log("incorrect signBit rejected: PASS");

console.log("XEd25519 runtime verification: PASS");
console.log("valid signature: PASS");
console.log("tampered message: PASS");
console.log("tampered signature: PASS");
console.log("invalid R.y field range: PASS");
console.log("invalid s range: PASS");
