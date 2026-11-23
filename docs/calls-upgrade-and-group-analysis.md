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

## Second slice: in-app group voice/video mesh (test candidate)

### Implemented architecture: small private mesh rooms (2–4 participants)

Use **one RTCPeerConnection per remote participant** with independent ICE,
connection state, audio and video renderers, but one local camera/microphone
capture shared across participants. This avoids a third-party SFU possessing
the decrypted media, and bounds upload cost: for four participants the local
device sends three encoded media paths. Gate larger rooms until a dedicated,
audited E2EE-capable SFU architecture is available.

The in-app test build now includes an authenticated room invitation and join
flow, local membership-digest validation, monotonic media state, independent
per-peer WebRTC connections with a shared local media capture, bounded ICE
queues, 2×2 tiles, camera/mic/speaker controls, periodic presence messages,
participant leave without tearing down other connections, and a hard
four-device cap. The original 1:1 call coordinator remains separate.

**Not completed for a production claim:**

1. **Native background behavior:** group invitations are currently delivered
   when the app is running and receiving relay messages. Android call wake,
   lock-screen answer/decline, foreground media service, and screen-off audio
   continuation are **not** yet completed for group calls.
2. **Resilience:** reconnect/backoff and an explicit rejoin-from-chat flow,
   plus lifecycle cleanup on account lock and Wanted Mode wipe need hardened
   device testing. The current implementation tears down failed peers, and
   periodic signed presence heals lost join notifications.
3. **Security hardening:** current media uses authenticated signaling and
   peer-to-peer DTLS-SRTP. Signal Sender Keys encrypt text, not media. Audit
   revocation, identity-key rotation, room collision and membership epoch
   handling before treating group media as a hardened E2EE product.
4. **Product polish:** active-speaker indicator, group call history, network
   quality hints, participant reconnect UI, and moderator/security audit.
5. **Verification:** three or four real Android devices on mixed Wi-Fi/mobile
   data, TURN-only tests, end-to-end audio/video, invite/accept/decline,
   participant leave/rejoin, lost network, permission denial, low-memory
   cleanup, battery and latency measurements.

This is a **test candidate**, not a production-ready claim, until the
cross-device tests and native lifecycle work above are complete. Group call
actions now route to a separate group room and never dial a group ID as if it
were a direct nickname.
