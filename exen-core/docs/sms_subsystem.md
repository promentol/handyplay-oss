# exen.Sms subsystem — canonical spec + port plan

Reverse-engineered 2026-07-03 from `emulator.c` (packages/exen-player/emulator/).
Class hash 0x6bddc5b7. Last unimplemented native family (idx 89–100 + Gamelet.sendSms 78);
~44 corpus gamelets use it for save/load/score. Line numbers → emulator.c.

## Object model

- Instance field **[8] (byte offset 32)** = ref to a native buffer object; the SMS struct
  `S = ref + 20` (20-byte VM header). `S` is 148 bytes (0x94). Accessor `sub_42989D` (:27785):
  `v2 = inst[8]; return v2 ? v2+20 : 0`.
- Instance dwords used as scratch by the natives:
  [9]/off36 = block-start bit cursor · [10]/off40 = current block id · [11]/off44 = current
  block length · [12]/off48 = skip/payload-bit accumulator · [13]/off52 = message-type index
  (MO_* selector; drives sendSms destination + getPrice tariff). `sub_429870` (:27775) zeroes [9..12].
- Struct `S`: S+0..3 = magic "EXEN"; **S+4..S+139 = 136-byte bit payload**; S+139 = checksum byte;
  S+140 = message-index copy (set at send); **S+144 = absolute bit cursor**.
- Cursor guards: writes reject if cursor > 0x42D (1069); reads/skips cap at 0x460 (1120); buffer = 1088 bits.

## Bit-stream core — MSB-first (big-endian bit packing)

Read `sub_412EA0(base, *cursor, nbits)` (:14983), write `sub_413071(base,*cursor,val,nbits)` (:15004):
first bit is the HIGH bit of the first byte; `byteIdx = cursor>>3`, `bitInByte = cursor&7`;
value packed `>> (8-bitInByte-nbits)`; ≤16-bit spans concat `(b0<<8)|b1`; ≤32 use bswap32 (memory
is LE, reinterpreted BE); cursor advances by nbits. A plain MSB-first bit reader/writer over S+4
reproduces it bit-identically for n≤32.
- `readBits` (idx 93, :27871): `*a1 = read(S+4, &cursor, a1[1])`, push 1.
- `writeBits` (idx 94, :27883): value=a1[1], nbits=a1[2], **clamped `if (nbits>7) nbits=8`** — writes ≤8 bits / a byte, push 0.
- `skipBits` (idx 99, :27983): `cursor += n; inst[12] += n` (guarded ≤0x460), push 0.

## Block format — [8-bit id][11-bit length][payload], 19-bit header

- `createBlock` (idx 92, :27854): save inst[9]=cursor, inst[10]=id; write **8-bit** id; reserve **11 bits** (cursor+=11). id width 8, length width 11 (max 2047).
- `endBlock` (idx 95, :27899): `len = cursor - (inst[9]+19)`; seek to blockStart+8; write 11-bit len via
  `sub_421B36` (:23172 — **3 hi bits then 8 lo bits**, MSB-first); restore cursor; `*a1 = len`, push 1.
- Read side: `getIdBlock` (idx 97, :27937) reads 8-bit id → inst[10], `*a1=id` (−1 if cursor≥0x460);
  `getLengthBlock` (idx 98, :27964) reads 11-bit len via `sub_421B7C` (:23179, `(read3<<8)|read8`) → inst[11];
  `nextBlock` (idx 96, :27924) `cursor += readLen11()` then reset [9..12] (skip current block).
- Read sequence: getIdBlock → (getLengthBlock + readBits payload) OR nextBlock to skip.

## createSms / variants / delete

- `createSms` (idx 90, :27799): cursor=0; `sub_4215FA` writes a **128-bit/16-byte header** (config bytes
  45FE8C[5],[7]; 16-bit gamelet id; 45FE8C[30..33] version; BCD date/time; +20-bit pad); then write 8-bit
  0x60 + reserved 11-bit 0 → **cursor = 147** (fixed prologue length); reset [9..12].
- `createSms(byte[])` (idx 91, :27820): copy 136 payload bytes from arg byte[]+20 into S+4, clear magic,
  cursor=0 — **read mode** for a received payload. (Currently stubbed in our port.)
- `deleteSms` (idx 89, :27848): empty `return 0` — GC owns the buffer; no-op, push 0.
- `getPrice` (idx 100): already done — "X.YY Euro(s)" tariff string.

## Send + reply (the "Waiting for a reply…" gate)

`Gamelet.sendSms` (idx 78, sub_4250C7 :25067): `Src=sub_42989D(inst); Src[35]=inst[13]`;
if `sub_423B1D(idx)` (destination configured in table `45FE8C+28*idx+400`, stride 28) AND
`sub_423A00(3)` (billing/period throttle) → `sub_4218D3(Src,1)` SEND; else `**(45FF3C+36)=3` (state 3 = error).
Real send: `sub_4218D3` appends signature/highscore blocks + 0xFF terminator + checksum, then
`sub_406514` → host thunk `sub_434EFE`/`sub_434F76` TCP to an SMS server (ini 192.168.0.46:5555),
posts **event 257** (send result: status 1=sent, 2=fail). Incoming replies arrive on a listener
socket into a 10-slot ring, pumped per-frame → **event 256** (incoming SMS).

Event dispatch (`sub_402F7C` :5471):
- **257 send-result** → `sub_402FBF` → `sub_415538(success)` → gamelet callback **onSmsSent(boolean)** at
  context vtable **+32** (hash 0x305a7631; SMS_SENT_SUCCESSFULLY/UNSUCCESSFULLY). **This releases the
  "Waiting for a reply…" screen.**
- **256 incoming** → `sub_41509C` (:16048): platform parses the 140-byte payload (checksum verify, block
  loop; block ids 7/8/9 packed 7-bit, others 8-bit; dispatch id&0x1F / id>>5 to built-in MT handler tables
  off_456C7C/CE4/CE0 — e.g. save restore via exonsavectx/exonloadctx sub_4153F8/sub_41547B), then callback
  **onSmsReceived** at vtable **+36** (hash 0x6f6c0565).

MO_* (mobile-originated: SAVE/LOAD/SCORE/RANKING/UNLOCK…) and MT_* (reply blocks the platform applies)
are block-id VALUES the gamelet read/writeBits — NOT event ids. Events are only 256/257.

## No-network reimplementation plan

1. Struct + MSB-first bit cursor exactly as above; all natives are thin wrappers over read/write + the
   header helpers (sub_421B36 write-3+8 / sub_421B7C read-3+8 / sub_421AF2 read-8 / sub_421982 write-8).
2. Block format id=8, len=11 (3<<8|8), 19-bit header; endBlock back-patch at blockStart+8. Honor guards.
3. **sendSms: skip both gates, synthesize immediate success** — reproduce `sub_402FBF`(status 1) →
   `sub_415538(1)`: fire the gamelet `onSmsSent(true)` callback (vtable +32) + SMS_SENT_SUCCESSFULLY.
   This alone advances MutantAlert past "Waiting for a reply…".
4. If a game needs an MT reply (MO_LOAD→MT_LOAD save data, MO_UNLOCK→MT_REQUESTED_ITEM): synthesize an
   event-256 payload = one block with the expected MT_* id + minimal/persisted payload + 0xFF terminator +
   valid checksum (8-bit sum of the 135 payload bytes), feed through the parse path, fire onSmsReceived.
   For save/load, service MO_SAVE/MO_LOAD against the existing 300-byte EEPROM (exonsavectx/loadctx) and
   reply success — no server needed.

## Uncertainties (NOT byte-confirmed)
- Callback vtable pairing: +32 onSmsSent (drives MutantAlert, well-supported) vs +36 onSmsReceived (plausible, not traced to a caller).
- Message-level length field placement in sub_4218D3 (per-block endBlock back-patch is confirmed; the message-level `sub_421B36(v3,v5)` append vs header-slot back-patch is only partially traced).

## Our current partial port (natives/exen/Sms.zig) — needs rework
deleteSms/createSms/createBlock/endBlock draft-implemented against an INVENTED layout (fake hashes
0xC0FFEE2x, 148-byte buffer, cursor@+144) — the buffer size (148/0x94) and cursor offset (+144) happen to
match canonical, but the instance-field indirection (field[8]→ref+20) and MSB-first bit packing must be
verified/redone. readBits/writeBits/createSms(byte[])/nextBlock/getIdBlock/getLengthBlock/skipBits stubbed.
