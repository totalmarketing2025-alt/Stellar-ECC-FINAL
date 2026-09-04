import express from 'express';

const app = express();
const PORT = Number(process.env.PORT || 8080);

app.use(express.json({ limit: '64kb' }));

const users = new Map();

function normalizeNickname(value) {
  return String(value || '').trim().toLowerCase();
}

function isValidNickname(nickname) {
  return /^[a-z0-9_]{3,32}$/.test(nickname);
}

function validateBundle(bundle) {
  if (!bundle || typeof bundle !== 'object') {
    return false;
  }

  if (!Number.isInteger(bundle.registrationId)) {
    return false;
  }

  if (!Number.isInteger(bundle.deviceId)) {
    return false;
  }

  if (typeof bundle.identityKey !== 'string' ||
      bundle.identityKey.length === 0) {
    return false;
  }

  if (!bundle.signedPreKey ||
      typeof bundle.signedPreKey !== 'object') {
    return false;
  }

  if (!Number.isInteger(bundle.signedPreKey.keyId) ||
      typeof bundle.signedPreKey.publicKey !== 'string' ||
      typeof bundle.signedPreKey.signature !== 'string') {
    return false;
  }

  if (!bundle.preKey ||
      typeof bundle.preKey !== 'object') {
    return false;
  }

  if (!Number.isInteger(bundle.preKey.keyId) ||
      typeof bundle.preKey.publicKey !== 'string') {
    return false;
  }

  return true;
}

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    service: 'stellar-directory',
  });
});

app.get('/v1/nickname/:nickname', (req, res) => {
  const nickname = normalizeNickname(req.params.nickname);

  if (!isValidNickname(nickname)) {
    return res.status(400).json({
      error: 'invalid_nickname',
    });
  }

  res.json({
    available: !users.has(nickname),
  });
});

app.post('/v1/register', (req, res) => {
  const nickname = normalizeNickname(req.body?.nickname);
  const bundle = req.body?.bundle;

  if (!isValidNickname(nickname)) {
    return res.status(400).json({
      error: 'invalid_nickname',
    });
  }

  if (!validateBundle(bundle)) {
    return res.status(400).json({
      error: 'invalid_signal_bundle',
    });
  }

  if (users.has(nickname)) {
    return res.status(409).json({
      error: 'nickname_taken',
    });
  }

  users.set(nickname, {
    nickname,
    registrationId: bundle.registrationId,
    deviceId: bundle.deviceId,
    identityKey: bundle.identityKey,
    signedPreKey: {
      keyId: bundle.signedPreKey.keyId,
      publicKey: bundle.signedPreKey.publicKey,
      signature: bundle.signedPreKey.signature,
    },
    preKey: {
      keyId: bundle.preKey.keyId,
      publicKey: bundle.preKey.publicKey,
    },
  });

  return res.status(201).json({
    nickname,
    registered: true,
  });
});

app.get('/v1/users/:nickname', (req, res) => {
  const nickname = normalizeNickname(req.params.nickname);
  const user = users.get(nickname);

  if (!user) {
    return res.status(404).json({
      error: 'user_not_found',
    });
  }

  res.json(user);
});

app.listen(PORT, () => {
  console.log(`Stellar Directory listening on port ${PORT}`);
});
