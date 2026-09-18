function normalizeNickname(value) {
  return String(value || "").trim().toLowerCase();
}

function validNickname(nickname) {
  return /^[a-z0-9_]{3,32}$/.test(nickname);
}


const PUSH_CHALLENGE_TTL_MS = 5 * 60 * 1000;

const CURVE25519_P = (1n << 255n) - 19n;

function createPushChallenge() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);

  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function buildPushAuthMessage({
  nickname,
  deviceId,
  registrationId,
  platform,
  token,
  challenge,
}) {
  return JSON.stringify([
    "stellar-push-v1",
    nickname,
    deviceId,
    registrationId,
    platform,
    token,
    challenge,
  ]);
}

function decodeBase64(value) {
  if (typeof value !== "string" || value.length === 0) {
    return null;
  }

  try {
    const normalized = value
      .replace(/-/g, "+")
      .replace(/_/g, "/");

    const padded =
      normalized + "=".repeat((4 - (normalized.length % 4)) % 4);

    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);

    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }

    return bytes;
  } catch (_) {
    return null;
  }
}

function bytesToBigIntLE(bytes) {
  let value = 0n;

  for (let i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8n) | BigInt(bytes[i]);
  }

  return value;
}

function bigIntToBytesLE(value, length) {
  const bytes = new Uint8Array(length);
  let current = value;

  for (let i = 0; i < length; i++) {
    bytes[i] = Number(current & 0xffn);
    current >>= 8n;
  }

  return bytes;
}

function mod(value, modulus) {
  const result = value % modulus;
  return result >= 0n ? result : result + modulus;
}

function modPow(base, exponent, modulus) {
  let result = 1n;
  let current = mod(base, modulus);
  let power = exponent;

  while (power > 0n) {
    if (power & 1n) {
      result = (result * current) % modulus;
    }

    current = (current * current) % modulus;
    power >>= 1n;
  }

  return result;
}

function modInverse(value, modulus) {
  if (value === 0n) {
    throw new Error("inverse of zero");
  }

  return modPow(value, modulus - 2n, modulus);
}

function curve25519PublicToEd25519Public(
  montgomeryPublicKey,
  signBit,
) {
  if (montgomeryPublicKey.length !== 32) {
    return null;
  }

  if (signBit !== 0 && signBit !== 1) {
    return null;
  }

  const u = bytesToBigIntLE(montgomeryPublicKey);

  if (u >= CURVE25519_P) {
    return null;
  }

  const denominator = mod(u + 1n, CURVE25519_P);

  if (denominator === 0n) {
    return null;
  }

  const y = mod(
    (u - 1n) * modInverse(denominator, CURVE25519_P),
    CURVE25519_P,
  );

  const encoded = bigIntToBytesLE(y, 32);

  encoded[31] &= 0x7f;
  encoded[31] |= signBit << 7;

  return encoded;
}

async function verifySignalIdentitySignature({
  identityKey,
  message,
  signature,
}) {
  const publicKey = decodeBase64(identityKey);
  const sig = decodeBase64(signature);

  if (!publicKey || publicKey.length !== 33 || publicKey[0] !== 0x05) {
    return false;
  }

  if (!sig || sig.length !== 64) {
    return false;
  }

  try {
    /*
     * Signal/XEd25519:
     * identityKey = 0x05 || little-endian Curve25519 u-coordinate.
     *
     * XEdDSA convert_mont() maps that Montgomery u-coordinate to
     * an Edwards public key and forces the Edwards sign bit to zero.
     */
    const montgomeryPublicKey = publicKey.slice(1);

    /*
     * XEdDSA first validates the encoded Montgomery u-coordinate.
     * convert_mont() masks the high bit only when converting it.
     */
    const u = bytesToBigIntLE(montgomeryPublicKey);

    if (u >= CURVE25519_P) {
      return false;
    }

    const rBytes = sig.slice(0, 32);
    const sBytes = sig.slice(32);

    /*
     * R is a compressed Edwards point:
     *   - low 255 bits encode y
     *   - high bit encodes the Edwards sign
     *
     * The sign bit must not be treated as part of y.
     */
    const rYBytes = rBytes.slice();
    rYBytes[31] &= 0x7f;

    const rY = bytesToBigIntLE(rYBytes);
    const s = bytesToBigIntLE(sBytes);

    /*
     * XEdDSA uses a 253-bit scalar range for s.
     */
    const CURVE25519_Q =
      (1n << 252n) +
      27742317777372353535851937790883648493n;

    if (rY >= CURVE25519_P || s >= CURVE25519_Q) {
      return false;
    }

    const montgomeryPublicKeyForConversion =
      montgomeryPublicKey.slice();

    montgomeryPublicKeyForConversion[31] &= 0x7f;

    const edPublicKey = curve25519PublicToEd25519Public(
      montgomeryPublicKeyForConversion,
      0,
    );

    if (!edPublicKey) {
      return false;
    }

    /*
     * XEd25519 signatures are Ed25519-compatible after the public-key
     * conversion above. WebCrypto provides the Ed25519 verification
     * primitive; the conversion itself follows Signal XEdDSA.
     */
    const cryptoKey = await crypto.subtle.importKey(
      "raw",
      edPublicKey,
      {
        name: "Ed25519",
      },
      false,
      ["verify"],
    );

    const messageBytes = new TextEncoder().encode(message);

    return await crypto.subtle.verify(
      {
        name: "Ed25519",
      },
      cryptoKey,
      sig,
      messageBytes,
    );
  } catch (error) {
    console.log("PUSH_SIGNATURE_VERIFY_FAILED", error);
    return false;
  }
}
function validSignalPublicKey(value) {
  const bytes = decodeBase64(value);

  return Boolean(
    bytes &&
    bytes.length === 33 &&
    bytes[0] === 0x05,
  );
}

function validSignalSignature(value) {
  const bytes = decodeBase64(value);

  return Boolean(
    bytes &&
    bytes.length === 64,
  );
}

function validSignalBundle(bundle, requirePreKey = true) {
  if (!bundle || typeof bundle !== "object") {
    return false;
  }

  if (!Number.isInteger(bundle.registrationId) ||
      bundle.registrationId < 1 ||
      bundle.registrationId > 0x7fffffff) {
    return false;
  }

  if (!Number.isInteger(bundle.deviceId) ||
      bundle.deviceId < 1 ||
      bundle.deviceId > 0x7fffffff) {
    return false;
  }

  if (!validSignalPublicKey(bundle.identityKey)) {
    return false;
  }

  const signedPreKey = bundle.signedPreKey;

  if (!signedPreKey ||
      typeof signedPreKey !== "object" ||
      !Number.isInteger(signedPreKey.keyId) ||
      signedPreKey.keyId < 0 ||
      signedPreKey.keyId > 0x7fffffff ||
      !validSignalPublicKey(signedPreKey.publicKey) ||
      !validSignalSignature(signedPreKey.signature)) {
    return false;
  }

  if (bundle.preKey == null) {
    return !requirePreKey;
  }

  if (!bundle.preKey ||
      typeof bundle.preKey !== "object" ||
      !Number.isInteger(bundle.preKey.keyId) ||
      bundle.preKey.keyId < 0 ||
      bundle.preKey.keyId > 0x7fffffff ||
      !validSignalPublicKey(bundle.preKey.publicKey)) {
    return false;
  }

  return true;
}

function publicUserRecord(user) {
  return {
    nickname: user.nickname,
    bundle: user.bundle,
  };
}


function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

export class DirectoryStore {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/v1/nickname") {
      const nickname = normalizeNickname(
        url.searchParams.get("nickname"),
      );

      if (!validNickname(nickname)) {
        return json({
          available: false,
          error: "Invalid nickname",
        }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      return json({
        available: !user,
        nickname,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/nickname/")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/nickname/".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({
          available: false,
          error: "Invalid nickname",
        }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      return json({
        available: !user,
        nickname,
      });
    }

    if (
      request.method === "POST" &&
      url.pathname === "/v1/internal/relay-auth"
    ) {
      const authorization =
        request.headers.get("Authorization") || "";

      const expectedSecret =
        this.env.RELAY_SHARED_SECRET || "";

      if (
        !expectedSecret ||
        authorization !== `Bearer ${expectedSecret}`
      ) {
        return json({ error: "Unauthorized" }, 401);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(
        typeof body.nickname === "string"
          ? body.nickname
          : "",
      );

      const deviceId = Number(body.deviceId);
      const registrationId = Number(body.registrationId);

      const challenge =
        typeof body.challenge === "string"
          ? body.challenge
          : "";

      const signature =
        typeof body.signature === "string"
          ? body.signature
          : "";

      if (
        !validNickname(nickname) ||
        !Number.isInteger(deviceId) ||
        deviceId <= 0 ||
        !Number.isInteger(registrationId) ||
        registrationId <= 0 ||
        !challenge ||
        !signature
      ) {
        return json({
          error: "Invalid relay auth request",
        }, 400);
      }

      const user =
        await this.ctx.storage.get(`user:${nickname}`);

      if (!user || !user.bundle) {
        return json({
          error: "User not found",
        }, 404);
      }

      const bundle = user.bundle;

      if (
        Number(bundle.deviceId) !== deviceId ||
        Number(bundle.registrationId) !== registrationId
      ) {
        return json({
          error: "identity_mismatch",
        }, 409);
      }

      const authMessage = JSON.stringify([
        "stellar-relay-v1",
        nickname,
        deviceId,
        registrationId,
        challenge,
      ]);

      const verified =
        await verifySignalIdentitySignature({
          identityKey: bundle.identityKey,
          message: authMessage,
          signature,
        });

      if (!verified) {
        return json({
          error: "Invalid relay signature",
        }, 401);
      }

      return json({ ok: true });
    }

    if (request.method === "PUT" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/bundle")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/users/".length, url.pathname.length - "/bundle".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      if (!validSignalBundle(body.bundle, true)) {
        return json({ error: "Invalid bundle" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const existingBundle = existing.bundle;

      if (existingBundle?.identityKey !== body.bundle.identityKey ||
          existingBundle?.registrationId !== body.bundle.registrationId ||
          existingBundle?.deviceId !== body.bundle.deviceId) {
        return json({ error: "Identity mismatch" }, 409);
      }

      const user = {
        ...existing,
        bundle: body.bundle,
      };

      await this.ctx.storage.put(key, user);

      return json({
        ok: true,
        nickname,
        updated: true,
      });
    }


    if (request.method === "DELETE" &&
        url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token")) {
      const auth = request.headers.get("authorization") || "";
      const expected = this.env.RELAY_SHARED_SECRET || "";
      if (!expected || auth !== `Bearer ${expected}`) {
        return json({ error: "Unauthorized" }, 401);
      }

      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token".length,
          ),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const token =
        typeof body.token === "string"
          ? body.token.trim()
          : "";

      if (!token || token.length > 4096) {
        return json({ error: "Invalid push token" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const registrations = Array.isArray(existing.pushRegistrations)
        ? existing.pushRegistrations.filter(
            (registration) =>
              registration &&
              typeof registration === "object" &&
              typeof registration.token === "string" &&
              registration.token,
          )
        : existing.push &&
          typeof existing.push === "object" &&
          typeof existing.push.token === "string" &&
          existing.push.token
          ? [
              {
                token: existing.push.token,
                platform: existing.push.platform,
                updatedAt: existing.push.updatedAt,
              },
            ]
          : [];

      const nextRegistrations = registrations.filter(
        (registration) => registration.token !== token,
      );

      if (nextRegistrations.length === registrations.length) {
        return json({
          ok: true,
          nickname,
          removed: false,
        });
      }

      const nextLegacyPush = nextRegistrations[0]
        ? {
            token: nextRegistrations[0].token,
            platform: nextRegistrations[0].platform,
            updatedAt: nextRegistrations[0].updatedAt,
          }
        : null;

      const user = {
        ...existing,
        pushRegistrations: nextRegistrations,
        push: nextLegacyPush,
      };

      await this.ctx.storage.put(key, user);

      return json({
        ok: true,
        nickname,
        removed: true,
      });
    }

    if (request.method === "POST" &&
        url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token/challenge")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token/challenge".length,
          ),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const deviceId =
        typeof body.deviceId === "number"
          ? body.deviceId
          : null;

      const registrationId =
        typeof body.registrationId === "number"
          ? body.registrationId
          : null;

      if (!Number.isInteger(deviceId) ||
          !Number.isInteger(registrationId)) {
        return json({
          error: "Invalid device identity",
        }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const existingBundle = existing.bundle;

      if (!existingBundle ||
          typeof existingBundle.registrationId !== "number" ||
          typeof existingBundle.deviceId !== "number" ||
          existingBundle.registrationId !== registrationId ||
          existingBundle.deviceId !== deviceId) {
        return json({
          error: "Identity mismatch",
        }, 409);
      }

      const challengeKey =
        `push-challenge:${nickname}:${deviceId}:${registrationId}`;

      const now = Date.now();
      const stored = await this.ctx.storage.get(challengeKey);

      if (stored &&
          typeof stored.challenge === "string" &&
          typeof stored.expiresAt === "number" &&
          stored.expiresAt > now) {
        return json({
          nickname,
          challenge: stored.challenge,
          expiresAt: stored.expiresAt,
        });
      }

      const challenge = createPushChallenge();
      const expiresAt = now + PUSH_CHALLENGE_TTL_MS;

      await this.ctx.storage.put(
        challengeKey,
        {
          challenge,
          expiresAt,
        },
      );

      return json({
        nickname,
        challenge,
        expiresAt,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token")) {
      const auth = request.headers.get("authorization") || "";
      const expected = this.env.RELAY_SHARED_SECRET || "";
      if (!expected || auth !== `Bearer ${expected}`) {
        return json({ error: "Unauthorized" }, 401);
      }

      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token".length,
          ),
        ),
      );
      if (!validNickname(nickname)) return json({ error: "Invalid nickname" }, 400);

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);
      if (!existing) return json({ error: "User not found" }, 404);

      const pushRegistrations = Array.isArray(existing.pushRegistrations)
        ? existing.pushRegistrations
        : [];

      return json({
        nickname,
        pushRegistrations,
        push: existing.push ?? pushRegistrations[0] ?? null,
      });
    }

    if (request.method === "PUT" && url.pathname.startsWith("/v1/users/") &&
        url.pathname.endsWith("/push-token")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring(
            "/v1/users/".length,
            url.pathname.length - "/push-token".length,
          ),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      let body;
      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const token =
        typeof body.token === "string"
          ? body.token.trim()
          : "";

      const platform =
        typeof body.platform === "string"
          ? body.platform.trim().toLowerCase()
          : "";

      const challenge =
        typeof body.challenge === "string"
          ? body.challenge.trim()
          : "";

      const signature =
        typeof body.signature === "string"
          ? body.signature.trim()
          : "";

      if (!token ||
          token.length > 4096 ||
          !["android", "ios"].includes(platform) ||
          !challenge ||
          challenge.length > 512 ||
          !signature) {
        return json({ error: "Invalid push authorization" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (!existing) {
        return json({ error: "User not found" }, 404);
      }

      const existingBundle = existing.bundle;

      if (!existingBundle ||
          typeof existingBundle.identityKey !== "string" ||
          typeof existingBundle.registrationId !== "number" ||
          typeof existingBundle.deviceId !== "number") {
        return json({
          error: "Push authorization unavailable",
        }, 409);
      }

      const challengeKey =
        `push-challenge:${nickname}:${existingBundle.deviceId}:${existingBundle.registrationId}`;
      const storedChallenge =
        await this.ctx.storage.get(challengeKey);

      const now = Date.now();

      if (!storedChallenge ||
          storedChallenge.challenge !== challenge ||
          typeof storedChallenge.expiresAt !== "number" ||
          storedChallenge.expiresAt <= now) {
        if (storedChallenge) {
          await this.ctx.storage.delete(challengeKey);
        }

        return json({
          error: "Invalid or expired push challenge",
        }, 401);
      }

      const authMessage = buildPushAuthMessage({
        nickname,
        deviceId: existingBundle.deviceId,
        registrationId: existingBundle.registrationId,
        platform,
        token,
        challenge,
      });

      const validSignature =
        await verifySignalIdentitySignature({
          identityKey: existingBundle.identityKey,
          message: authMessage,
          signature,
        });

      if (!validSignature) {
        return json({
          error: "Invalid push authorization",
        }, 401);
      }

      await this.ctx.storage.delete(challengeKey);

      const registrations = Array.isArray(existing.pushRegistrations)
        ? existing.pushRegistrations.filter(
            (registration) =>
              registration &&
              typeof registration === "object" &&
              typeof registration.token === "string" &&
              typeof registration.platform === "string" &&
              typeof registration.deviceId === "number" &&
              typeof registration.registrationId === "number",
          )
        : [];

      if (registrations.length === 0 &&
          existing.push &&
          typeof existing.push === "object" &&
          typeof existing.push.token === "string" &&
          typeof existing.push.platform === "string") {
        registrations.push({
          token: existing.push.token,
          platform: existing.push.platform,
          deviceId: existingBundle.deviceId,
          registrationId: existingBundle.registrationId,
          updatedAt: typeof existing.push.updatedAt === "number"
              ? existing.push.updatedAt
              : now,
        });
      }

      const nextRegistrations = registrations.filter(
        (registration) =>
          registration.deviceId !== existingBundle.deviceId ||
          registration.registrationId !== existingBundle.registrationId ||
          registration.platform !== platform,
      );

      const withoutDuplicateToken = nextRegistrations.filter(
        (registration) => registration.token !== token,
      );

      withoutDuplicateToken.push({
        token,
        platform,
        deviceId: existingBundle.deviceId,
        registrationId: existingBundle.registrationId,
        updatedAt: now,
      });

      const user = {
        ...existing,
        pushRegistrations: withoutDuplicateToken,
        push: {
          token,
          platform,
          updatedAt: now,
        },
      };

      await this.ctx.storage.put(key, user);

      return json({
        ok: true,
        nickname,
        registered: true,
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v1/users/")) {
      const nickname = normalizeNickname(
        decodeURIComponent(
          url.pathname.substring("/v1/users/".length),
        ),
      );

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      const user = await this.ctx.storage.get(`user:${nickname}`);

      if (!user) {
        return json({ error: "User not found" }, 404);
      }

      return json(publicUserRecord(user));
    }

    if (request.method === "POST" && url.pathname === "/v1/register") {
      let body;

      try {
        body = await request.json();
      } catch (_) {
        return json({ error: "Invalid JSON" }, 400);
      }

      const nickname = normalizeNickname(body.nickname);

      if (!validNickname(nickname)) {
        return json({ error: "Invalid nickname" }, 400);
      }

      if (!validSignalBundle(body.bundle, true)) {
        return json({ error: "Invalid bundle" }, 400);
      }

      const key = `user:${nickname}`;
      const existing = await this.ctx.storage.get(key);

      if (existing) {
        return json({
          error: "Nickname already registered",
        }, 409);
      }

      const user = {
        nickname,
        bundle: body.bundle,
      };

      await this.ctx.storage.put(key, user);

      return json({
        ok: true,
        nickname,
      }, 201);
    }

    if (request.method === "GET" && url.pathname === "/v1/users") {
      const result = await this.ctx.storage.list({
        prefix: "user:",
      });

      const users = [];

      for (const value of result.values()) {
        if (value && typeof value.nickname === "string") {
          users.push(value.nickname);
        }
      }

      users.sort();

      return json({ users });
    }

    return new Response("Not Found", { status: 404 });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({
        ok: true,
        service: "stellar-directory",
      });
    }

    if (
      !url.pathname.startsWith("/v1/")
    ) {
      return new Response("Not Found", {
        status: 404,
      });
    }

    const id = env.DIRECTORY.idFromName("global");
    const stub = env.DIRECTORY.get(id);

    return stub.fetch(request);
  },
};
