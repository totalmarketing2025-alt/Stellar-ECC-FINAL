# STELLAR ECC calls: inspected architecture and next implementation phases

## Baseline (23 November 2026)

- `CallService` owns precisely **one** `RTCPeerConnection`, its camera/audio
  capture streams, a single remote renderer and one remote nickname.
- `CallCoordinator` owns one `CallSession` and rejects any second concurrent
  offer with `busy`. The authenticated call signal is tied to a fixed `callId`,
  `chatId`, initial `kind` and peer identity. ICE is buffered around offers.
- A Directory-issued TURN configuration is used by WebRTC, with signed
  plain-text relay signaling (`STELLAR_CALL_V1:`). The call *signaling* is
  authenticated, **not** Signal-message encrypted. WebRTC's negotiated
  transport encrypts audio/video via DTLS-SRTP; group E2EE is a separate task.
- Separate voice/video screens previously re-created a call on entry and
  terminated it when disposed. Native Android ringing/lock-screen controls
  and call-history entries are based on the original `kind`.
- Group chats use Signal Sender Keys, but the group-management UI still has a
  placeholder in-memory membership list. **No multiparty call protocol exists.**

## Delivered by the first slice: 1:1 camera switching

1. Reserve the video sender/transceiver at setup, even for audio-only calls;
   do not capture the camera for the initial voice call.
2. Attach a camera track to the already negotiated sender, or replace it with
   `null` and release capture when switched off. The audio track, `callId`,
   WebRTC connection, timer and existing conversation persist.
3. Add a signed, replay-guarded `media-state` payload with a monotonically
   increasing revision. Keep original call `kind` as the authenticated
   **invitation type**, and represent the evolving camera state separately.
4. Let each participant independently enable video. Never remotely activate
   the *other person's* camera; this must be their own explicit button press.
5. The receiving UI displays video only when the peer advertised it. If the
   camera permission is denied or the switch fails, the existing audio call
   continues.

## Next slice: real group voice/video calls (not implemented yet)

### Proposed initial product: small private mesh rooms (2–4 participants)

Use **one RTCPeerConnection per remote participant** with independent ICE,
connection state, audio and video renderers, but one local camera/microphone
capture shared across participants. This avoids a third-party SFU possessing
the decrypted media, and bounds upload cost: for four participants the local
device sends three encoded media paths. Gate larger rooms until a dedicated,
audited E2EE-capable SFU architecture is available.

Required modules and invariants:

1. **Group identity and membership:** load authoritative local group
   membership from `ChatDao.groupMembers`; verify signed invite/send/join
   membership on receipt; reject outsiders, removed users and stale epochs.
2. **Room protocol:** authenticated group `roomId`, membership epoch,
   participant ID, per-peer `pairCallId`, per-peer ordered offer/answer/ICE,
   invite/join/leave/busy/timeout; separate from existing 1:1 signal routing.
   Include a replay cache, bounded queues and strict sender/recipient checks.
3. **Coordinator:** map participant → peer connection, cancel one participant
   without ending everybody, track reconnect/backoff, support active speaker
   and independent camera/mic status. Limit simultaneous joins and teardown
   all tracks on account lock and Wanted Mode wipe.
4. **UI:** group-chat voice/video call actions, incoming room invitation,
   2–4 tiles, participant names, speaking indicators, host-free join/leave,
   camera/mic/speaker/switch controls and screen-off audio continuation.
5. **Native notifications:** group invitation channel, background wake,
   accept/decline/rejoin identities, Android foreground camera/microphone
   service requirements. Do not reuse a single-peer call ID for a group.
6. **Security:** DTLS fingerprints per peer, authenticated membership updates,
   key rotation when a member leaves, and a documented media E2EE threat
   model. Avoid implying that Signal Sender Keys automatically encrypt media.
7. **Verification:** three real Android devices on mixed Wi-Fi/mobile data,
   TURN-only tests, audio routing, push background/locked-screen entry,
   leave/rejoin, lost network, camera permissions, 2→4 participants,
   low-memory cleanup, battery and latency measurements.

Do not expose a "working group call" button until these elements are wired and
validated end to end. A group chat's current voice/video actions must not
silently dial the group ID as if it were one nickname.
