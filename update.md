# Update v1.54 — Ruin Gate + Throttle Inventaris

EA: `EA_v1.53-FTG.mq5` → **v1.54** | Tanggal: 2026-09-07
Status: **terkompilasi bersih (0 error, 0 warning)** via MetaEditor, `.ex5` ikut terbentuk.

> **Lanjutan v1.55** (pembersih ranjau SL) — lihat bagian di bawah.
> File: `EA_v1.55-Ruin-FTG.mq5` (salinan dari `EA_v1.53-Ruin-FTG.mq5` = v1.54),
> terkompilasi 0 error / 0 warning, `.ex5` ikut terbentuk.

---

## Latar belakang (kenapa update ini dibuat)

Tiga akun v1.53 hangus dalam sehari masing-masing dengan pola identik:

| Akun | Periode | Modal | Hasil | Basket terminal |
|---|---|---|---|---|
| MC-v1.53-C | 21 Agt | 18.842 | **habis (−104,77)** | BUY 109 pos / 7,58 lot = −16.296 |
| MC-v1.53-D | 24–25 Agt | 10.378 | **habis (−831,72)** | SELL 83 pos / 4,22 lot = −14.283 |
| MC-v1.53-FTG | 25–26 Agt | 10.000 | **habis (−172,45)** | SELL 96 pos / 6,17 lot = −12.730 |

Fakta kunci dari analisis report:

1. **Ketiga akun mati oleh STOP-OUT broker, bukan keputusan EA.** Deal-deal
   terakhir bertanda komentar `[so ...]` — server menutup posisi satu per satu
   dari yang rugi terbesar (hasil ramp lot 0,08–0,15) sampai balance negatif.
2. **Ladder terus mengisi sampai detik terakhir.** Di akun C, posisi terakhir
   dibuka 8 detik sebelum stop-out; di sesi 7 Sep tercatat 3,42 lot terisi
   dalam 5 menit — fast trend gate lama hanya menahan order, kebocorannya ada
   di mode PROBE yang memasang limit ber-ramp dan cooldown statis.
3. **Recovery Grid mempercepat kegagalan.** Di akun D, 149 posisi RECOV
   (9,20 lot) merealisasikan **−3.241,55** (rata-rata −21,76/posisi, lebih
   buruk dari basket utama yang dilayaninya) dan ikut ter-stop-out.
4. **Exit dieksekusi di harga terburuk.** Basket 7 Sep 11:40 ditutup tepat di
   harga terendah hari itu (avg exit 4387,7; 6–8 menit kemudian harga sudah
   4388–4391).
5. **Floating protection (70% equity) menyala terlambat.** Pada akun C, saat
   FP aktif, sisa jarak ruin tinggal ±12–15 USD — ketiga akun mati *walau FP
   menyala*. FP mengukur kerugian yang sudah terjadi; yang dibutuhkan adalah
   ukuran ruang yang tersisa.

Prinsip yang TIDAK berubah: **tanpa cut loss**. Semua perubahan hanya mengatur
*kapan boleh menambah eksposur* dan *kapan waktunya mengeksekusi exit yang
sudah sah* — tidak ada satu pun jalur baru yang menutup posisi merugi.

---

## Perubahan

### 1. Ruin Gate (baru) — `InpUseRuinGate = true`

Sebelum refill ladder, EA menghitung **jarak ruin per basket**:
berapa USD harga masih boleh berjalan melawan basket sebelum equity habis
(`equity / (volume_basket × uang per lot per USD)`). Zona ditentukan dari
volume basket yang sudah terisi (pending sengaja tidak dihitung supaya zona
stabil, tidak osilasi karena cancel/refill):

- **Aman** (ruin > `InpMinRuinDistance` = 25 USD): ladder normal.
- **Genting** (≤ 25 USD): pending dibatasi `InpRuinPendingMax` = 3 level,
  refill maksimal **1 level per tick**.
- **Kritis** (≤ `InpRuinDistanceTight` = 10 USD): ladder mati total, semua
  pending dibatalkan. Posisi tetap dipegang, exit tetap berjalan.

Transisi zona dicetak sekali di journal (`RUIN GATE ... -> ZONA ...`).
Ambang 25/10 sengaja lebih tinggi dari ambang bahaya sesungguhnya karena
hitungan menuju equity nol, sedangkan stop-out broker terjadi lebih awal —
gate perlu menyala lebih dulu. Kalibrasi ulang dari log journal.

Bandingkan dengan floating protection: FP = lapis kedua yang menyala saat
kerugian gabungan ≥ 70% equity (sudah hampir jurang); ruin gate menyala
25 USD sebelum jurang, per basket, bertahap.

### 2. PROBE ditambal

- `InpProbeSingleLimit = true`: probe memasang **satu limit LOT DASAR**
  (bukan limit ber-ramp 0,05–0,15). Kebocoran 3,42 lot/5 menit lahir dari
  probe ber-ramp + refill batch penuh.
- Cooldown probe **menaik**: `InpTrendProbeCooldownSec` (10 dtk) +
  `InpProbeCooldownGrowSec` (30 dtk) untuk setiap kali arah jatuh kembali ke
  BLOCKED dari PROBE, dibatasi `InpProbeCooldownMaxSec` (90 dtk). Pola
  rilis-terlalu-cepat yang berulang dengan jeda sama persis jadi terputus.
  Streak reset setelah `InpTrendNormalSec` benar-benar tenang.

### 3. Sisi close

- `InpUseBurstCloseDelay = true`, `InpBurstCloseDelaySec = 45`: saat vstop
  tersentuh tetapi fast gate masih BLOCKED (burst), eksekusi CloseBasket
  **ditunda maksimal 45 detik** supaya menutup di harga tenang, bukan di
  puncak spike. Ratchet tetap berjalan dan tidak mundur; kalau harga mundur
  ke balik level, timer reset dan exit dicoba pada penyentuhan berikutnya.
- `InpCloseSpreadMax = 1,50 USD`: jangan MEMULAI close basket saat spread
  melebar (0 = off).
- `InpEdgePerLot = 0,10 USD/lot`: verifikasi margin exit kini menjumlahkan
  komponen per posisi (`InpExitEdgePerPos`) **dan per lot** — drift
  penutupan menumpuk per lot (menutup 7,58 lot makan jauh lebih lama dari
  61 posisi ber-volumen kecil).

### 4. Spread gate untuk entry & refill

- `InpMaxSpread` default **0 → 600 points** (0,60 USD pada XAUUSDm 3 digit;
  spread normal terukur 0,24). Kini juga menahan **refill** di
  `MaintainLadder`, bukan hanya anchor. Masih bisa dimatikan dengan 0.

### 5. Recovery Grid default OFF

- `InpUseRecovery` default **true → false** (bukti poin 3 di atas).
- Kunci panel lama (`recov`) dimigrasi ke **`recov_v154`**: toggle ON yang
  tertanam di GlobalVariable sesi lama tidak akan diam-diam menyalakan
  kembali modul yang sudah diputuskan mati. Tombol panel tetap berfungsi
  untuk menyalakannya manual.

### 6. Pelengkap

- Validasi OnInit untuk semua parameter baru (ambang bertingkat, batas atas
  cooldown, nilai non-negatif).
- Laporan OnInit menampilkan konfigurasi v1.54 untuk kalibrasi.
- `ClearCycleState()` membersihkan timer burst-close dan zona ruin basket.
- Panel status menampilkan cooldown probe + streak per arah.

---

## Input baru (grup "Ruin Gate & Eksekusi (v1.54)")

| Input | Default | Fungsi |
|---|---|---|
| `InpUseRuinGate` | true | Aktifkan ruin gate |
| `InpMinRuinDistance` | 25.0 | Zona genting: pending dibatasi (USD) |
| `InpRuinDistanceTight` | 10.0 | Zona kritis: ladder mati (USD) |
| `InpRuinPendingMax` | 3 | Pending maksimum saat genting |
| `InpProbeSingleLimit` | true | Probe = 1 limit lot dasar |
| `InpProbeCooldownGrowSec` | 30 | Tambahan cooldown per burst berulang |
| `InpProbeCooldownMaxSec` | 90 | Batas atas cooldown probe |
| `InpUseBurstCloseDelay` | true | Tunda exit selama gate BLOCKED |
| `InpBurstCloseDelaySec` | 45 | Maksimum penundaan exit (detik) |
| `InpEdgePerLot` | 0.10 | Margin exit tambahan per lot (USD) |
| `InpCloseSpreadMax` | 1.50 | Spread maksimum mulai close (USD, 0=off) |

Input yang berubah default: `InpUseRecovery` → false, `InpMaxSpread` → 600.

---

## Yang TIDAK berubah

- Rumus exit v1.43 di `RevEngExit.mqh` (arming BE+offset+buffer, trailing,
  ratchet anti-mundur).
- Ramp lot dan grid step (0,25 USD) — termasuk mekanisme perataan BE.
- Prinsip tanpa cut loss; jaring pengaman SL tetap di-clamp tidak pernah
  merugi (bisa berarti tanpa SL).
- Hedge lock (tetap default OFF), floating protection 70% equity (lapis kedua).
- Magic number, komentar order, format GlobalVariable yang lama (anchor,
  vstop, wallet) — restart-safe seperti sebelumnya.

---

## Batasan yang perlu diketahui (jujur)

Ruin gate **memperkecil ukuran bencana, tidak menghapusnya**. Dari zona
kritis, basket menunggu harga balik ke BE+target; kalau harga terus melawan
sampai sisa ruang (≤10 USD) habis, stop-out broker tetap menutup semua di
harga terburuk. Yang berubah dibanding v1.53: basket berhenti tumbuh jauh
lebih awal (±2,5× volume sejak gate menyala, lalu berhenti), jadi kerugian
akhir sebanding ukuran basket yang jauh lebih kecil. Selamat-tidaknya akun
tetap ditentukan rasio lot dasar terhadap equity dan keramahan harga.

## Saran pengujian

1. Backtest pada periode yang sama dengan tiga akun yang hangus
   (21 Agt dan 24–26 Agt 2026) — stress test terbaik: v1.53 mati dalam
   12–22 menit dari puncak.
2. Demo forward dengan setelan default; pantau baris `RUIN GATE` di journal:
   - sering GENTING di kondisi normal → longgarkan 25 (mis. 35);
   - masih menuju zona KRITIS lalu jebol → perketat (mis. 20/8) atau
     turunkan `InpBaseLot`.
3. Bandingkan expected payoff dan frekuensi basket menggantung melawan
   report v1.53 (baseline: PF 0,88, 66 loss beruntun, DD 21%).

---

# Update v1.55 — Pembersih Ranjau SL

EA: **v1.54 → v1.55** | Tanggal: 2026-09-08
File: `EA_v1.55-Ruin-FTG.mq5` + `.ex5` (terkompilasi 0 error / 0 warning).

## Hasil forward test v1.54 (11 Sep 11:36 → 8 Sep 12:28, `v1.54-Ruin-FTG.xlsx`)

| Metrik | v1.53 (3 akun + sesi 7 Sep) | v1.54 |
|---|---|---|
| Nasib akun | 3 stop-out, balance negatif | 0 stop-out, balance 21.751 → 25.043 |
| Realized | −18.947 / −15.519 / −12.735 / −1.032 | **+3.304** |
| Basket terburuk | −16.296 s/d −4.896 | **−862** |
| Basket terbesar | 7,58 lot / 109 posisi | 3,50 lot / 64 posisi |
| Max balance DD | −25.604 / −16.031 / −14.476 / −5.476 | **−1.523 (±6%)** |
| Win rate basket | 81–94% (satu ledakan menghapus semua) | 90%, tanpa ledakan |

EA sendiri tidak pernah menutup basket di rugi: semua close EA terverifikasi
profit. Dua close minus (−817, −251) ternyata **manual** (dikonfirmasi user);
satu lagi (−862) dari jaring SL — lihat di bawah.

## Celah yang ditemukan & diperbaiki

**Ranjau SL.** Jaring pengaman dipasang hanya di sisi aman BE, tapi BE bisa
NAIK melewatinya (fill ladder di dekat harga menarik BE mendekati pasar —
mekanisme perataan BE). Sejak itu SL lama yang dulunya legal menjadi ranjau:
8 Sep 09:53:50, harga jatuh menembus SL sebelum EA bereaksi → 33 posisi
dieksekusi server `[sl]` **−862**; EA menutup sisa 64 posisi +821 tiga detik
kemudian. Net −41 dari 5,33 lot — selamat, tapi karena keberuntungan.

**Perbaikan v1.55 (tetap tanpa cut loss):**

1. `RemoveLosingStops()`: saat clamp BE aktif (tidak ada SL legal yang bisa
   dipasang), SL lama di sisi RUGI BE **dihapus** dari posisi
   (`PositionModify(ticket, 0, tp)`). SL yang pasti merugi lebih baik tidak
   ada — posisi kembali dijaga penuh oleh trailing virtual. SL di sisi
   untung BE dibiarkan. Log: `RANJAU SL ...`.
2. Deteksi ranjau di loop sinkronisasi: SL yang kini berada di sisi rugi BE
   langsung disinkronkan ke kandidat legal sekarang (≥ BE, dijamin
   `NetStopCandidate`) **tanpa dedup advance** — jaraknya ke net tidak
   relevan, bahayanya ke BE. Mode baseline v1.43 tidak diubah.

## Catatan

- Dua close minus di forward test dikonfirmasi manual (bukan jalur EA).
- Perilaku baru berlaku otomatis, tanpa input tambahan.
- Lanjutkan forward test v1.55 di akun demo; pantau baris `RANJAU SL` di
  journal — jika muncul, berarti clamp BE pernah aktif dan ranjau berhasil
  dibersihkan sebelum dieksekusi broker.
