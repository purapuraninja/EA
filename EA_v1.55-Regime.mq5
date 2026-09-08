//+------------------------------------------------------------------+
//|                                              EA_Grid.mq5    |
//|  Replikasi perilaku EA grid counter-trend hasil analisis         |
//|  Trade History Report XAUUSDc (akun cent, mode hedge).           |
//|                                                                  |
//|  Mekanisme (sesuai data asli):                                   |
//|   1. Anchor market order (BaseLot) membuka siklus per arah.      |
//|   2. Ladder limit order searah pada sisi adverse, step 0.25 USD. |
//|      Buy-limit di bawah harga, sell-limit di atas harga.         |
//|   3. Ladder dijaga: selalu ada >= PendingBatch limit di depan    |
//|      harga; batch baru ditambahkan saat harga mendekat.          |
//|   4. Lot per level: 60 level pertama = BaseLot, lalu naik        |
//|      +BaseLot tiap 30 level (0.01 x60, 0.02 x30, 0.03 x30, ...). |
//|   5. Tanpa TP per posisi. Setelah target basket tercapai, level   |
//|      exit bersama mengikuti harga pada jarak TrailingDistance.    |
//|      Level hanya bergerak searah profit dan tidak pernah mundur.  |
//|      Acuan anti-mundur adalah level yang sudah tercapai (bukan    |
//|      target BE) sehingga level tetap bergeser walau BE berubah    |
//|      karena level ladder baru terisi.                            |
//|      Seluruh basket tertutup serentak saat harga menyentuh level. |
//|      Sejak v1.50 level ini disimpan di memori EA dan dieksekusi   |
//|      lewat PositionClose; SL server hanya jaring pengaman.        |
//|   6. Saat basket tertutup, semua limit sisa di-cancel. Sejak      |
//|      v1.50 cancel dilakukan LEBIH DULU, dalam satu jalur dengan   |
//|      close, lalu siklus baru dimulai setelah basket bersih.       |
//|   7. Grid BUY dan grid SELL berjalan independen (akun hedge).    |
//|   8. Soft trend filter M1: kondisi normal tetap dua arah; hanya   |
//|      siklus baru yang melawan impuls kuat yang ditahan sementara.|
//|   9. News filter opsional: menahan siklus baru di sekitar berita. |
//|  10. Floating protection: menahan siklus/anchor baru dan          |
//|      membatalkan semua limit yang belum terisi saat floating loss  |
//|      EA (profit+swap+komisi) mencapai batas persentase dari equity |
//|      akun. Posisi terbuka TIDAK ditutup; proteksi lepas otomatis   |
//|      saat rasio loss turun di bawah batas dan ladder dilanjutkan.  |
//|                                                                  |
//|  === v1.50: EXIT HYBRID ===                                      |
//|  Logika perhitungan exit di v1.43 benar, eksekusinya yang gagal.  |
//|  Tiga penyebab yang diperbaiki:                                  |
//|                                                                  |
//|   A. invalid stops (10016). Broker melaporkan STOPS_LEVEL 0 tapi  |
//|      menegakkan minimum dinamis, sehingga SL arming 0.10-0.20     |
//|      dari harga selalu ditolak dan basket tidak pernah ambil      |
//|      profit. Jarak minimum sekarang dihitung sendiri lewat        |
//|      EffectiveMinStopDistance() dan melebar sendiri saat ditolak. |
//|                                                                  |
//|   B. Exit parsial. SL adalah atribut per-posisi, sedangkan target |
//|      profit milik basket. Saat spike, satu burst men-trigger SL   |
//|      sekaligus mengisi limit di baliknya; fill baru lahir sl=0    |
//|      dan basket terbelah. Eksekusi exit sekarang dipegang         |
//|      CloseBasket() yang menutup seluruh magic dalam satu jalur.   |
//|                                                                  |
//|   C. Celah cancel pending. CancelAllPendings hanya jalan di state |
//|      IDLE, jadi ada satu tick di mana fill baru bisa menyusup.    |
//|      Sekarang pending dibatalkan LEBIH DULU di dalam CloseBasket. |
//|                                                                  |
//|  Desain: trailing virtual di memori EA jadi eksekutor utama       |
//|  (PositionClose), SL server hanya jaring pengaman di jarak legal  |
//|  broker. Jaring di-clamp ke BE basket: kalau jarak legal memaksa  |
//|  net melewati BE, net TIDAK dipasang. Tidak boleh ada SL merugi.  |
//|  Prinsip tanpa cut loss tidak berubah.                            |
//|                                                                  |
//|  Rumus trailing dipakai apa adanya dari v1.43: arming di          |
//|  BE +/- ProfitOffset + buffer, TrailingDistance, TrailingStep,    |
//|  tidak pernah mundur. Matematikanya dipindah ke RevEngExit.mqh    |
//|  sebagai fungsi murni supaya bisa diuji lepas dari broker.        |
//+------------------------------------------------------------------+
#property copyright "reverse engineered from trade history"

// Satu sumber kebenaran untuk identitas build. Dipakai bersama oleh
// #property version, semua log, dan panel ShowStatus. Di v1.43 angka
// versi di-hardcode di dua tempat dan sempat tidak sinkron.
#define EA_VERSION "1.55"
#property version   EA_VERSION
#property strict

#include <Trade/Trade.mqh>
#include "RevEngExit.mqh"

// Deviation normal untuk order masuk. Close basket memakai
// InpCloseSlippagePts yang jauh lebih longgar (lihat CloseBasket).
#define DEFAULT_DEVIATION_PTS 30

// Jumlah basket yang punya state sendiri: grid utama BUY/SELL, plus
// recovery BUY/SELL. Lihat SlotOf() untuk pemetaannya.
#define BASKET_SLOTS 4

//--- Input parameters -----------------------------------------------
input group  "=== Grid ==="
input double InpBaseLot        = 0.01;     // Lot dasar
input double InpGridStep       = 0.25;     // Jarak grid (USD per level)
input int    InpLevelsFlat     = 20;       // Jumlah level dengan lot dasar
input int    InpLevelsPerStep  = 10;       // Level per kenaikan +BaseLot
input int    InpPendingBatch   = 6;        // Minimum limit aktif di depan harga
input int    InpBatchRefill    = 6;        // Jumlah limit ditambah per refill

input group  "=== Exit ==="
input double InpProfitOffset     = 0.30;   // Target awal dari BE basket (USD)
input double InpSLBuffer         = 0.10;   // Jarak konfirmasi setelah target (USD)
input double InpTrailingDistance = 0.20;   // Jarak SL dari harga berjalan (USD)
input double InpTrailingStep     = 0.05;   // Minimum perpindahan SL (USD)

// v1.53c: TAMBAHAN margin exit per posisi, di atas target basket.
//
// Latar belakangnya: sebelum ini EA tidak pernah memeriksa apakah basket
// benar-benar untung pada tick eksekusi. Yang diperiksa hanya "apakah harga
// sudah melewati level" (IsVirtualStopHit). Dua hal bisa memisahkan keduanya:
//   (a) Harga melompat melewati level dalam satu tick. Level tidak pernah
//       tersentuh; yang tersentuh adalah harga di baliknya yang lebih buruk.
//   (b) BE bergeser sesudah level dikunci, karena ladder masih mengisi.
// Perbaikan intinya ada di titik trigger: margin nyata (harga vs BE) wajib
// >= target basket itu sendiri. Itu tidak butuh angka baru, hanya menagih
// janji yang sudah ditulis di InpProfitOffset / InpRecoveryTarget.
//
// Bukti dari New-v1.53.xlsx (474 posisi, 14 Agt 12:10-13:00, demo 463719930):
// 9 peristiwa penutupan berakhir minus, total -385,57. SEMBILAN-SEMBILANNYA
// punya margin nyata di bawah 0,30 pada tick trigger. Tidak ada satu pun
// penutupan rugi yang marginnya >= 0,30. Jadi pemeriksaan dasar itu sendiri
// sudah memblokir seluruhnya. Dua yang terbesar:
//
//   Basket SELL, 55 posisi, 1,39 lot, BE 4378,977 (target 4378,677).
//   Trigger nyata di 4378,951 = BE + 0,026 poin. Penutupan makan 36 detik
//   (12:30:42 -> 12:31:18), harga lari 1,449 poin melawan. Realisasi -313,74.
//
//   Basket BUY, 61 posisi, 1,71 lot, BE 4376,156 (target 4376,456).
//   Trigger nyata di 4376,043 = BE - 0,113: SUDAH minus di tick keputusan.
//   Bid melompat 4376,635 (12:49:04) -> 4376,043 (12:49:07), melewati level
//   0,413 poin. Penutupan 9 detik, harga lari 0,360 poin lagi.
//   Realisasi -63,01 = +51,30 target - 70,6 lompatan - 43,6 drift.
//
// Input ini menangani bagian KEDUA yang tidak tertutup target dasar:
// CloseBasket() menutup posisi satu per satu, jadi durasinya tumbuh seiring
// jumlah posisi - 9 detik untuk 61, 36 detik untuk 55. Selama itu harga
// jalan, dan pada 1,7 lot tiap 0,1 poin = 17 USD. Karena itu tambahannya
// dikali jumlah posisi, bukan angka rata: basket 3 posisi tutup dalam
// sedetik dan tidak perlu dihukum seperti basket 60 posisi.
//
//   0,015 -> 1 posisi: +0,015   10 posisi: +0,15
//            27 posisi: +0,41   55 posisi: +0,83   61 posisi: +0,92
//
// Jujur soal batasnya: drift tidak punya plafon, jadi margin di depan hanya
// menutup drift yang WAJAR, bukan yang terburuk. Kalau di log sering muncul
// EXIT DITAHAN lalu tetap berakhir minus, naikkan angka ini. 0 = tidak ada
// tambahan, target dasar tetap ditagih.
input double InpExitEdgePerPos   = 0.015;  // Tambahan margin exit per posisi (USD)

input group  "=== Eksekusi Exit (v1.50) ==="
// Kill switch. OFF = perilaku lama v1.43 (SL server jadi eksekutor,
// jarak trailing dilebarkan ke batas broker). Dipakai sebagai baseline
// pembanding saat regresi backtest.
input bool   InpUseVirtualTrailing = true;  // Trailing virtual jadi eksekutor exit
input bool   InpUseSafetyNetSL     = true;  // Pasang SL server sebagai jaring pengaman
// Jarak minimum SL dari harga. WAJIB DIKALIBRASI PER SIMBOL.
// XAUUSDm melaporkan STOPS_LEVEL 0 tapi menegakkan minimum dinamis, dan di
// sana default 0.50 ini lahir. XAUUSDc berperilaku lain: riwayat 5.194 trade
// menunjukkan 97,7% posisi ber-SL dan 33,5% ditutup tepat di SL pada jarak
// trailing 0.20, jadi 0.50 kemungkinan JAUH terlalu lebar di sana dan akan
// membuat clamp BE menahan jaring terus-menerus.
// Baca dump spesifikasi di OnInit pada simbol yang dipakai, jangan mewarisi
// angka dari simbol lain.
input double InpNetMinDistance     = 0.50;  // Jarak minimum jaring pengaman (USD)
input double InpNetSpreadMult      = 2.0;   // Kelipatan spread untuk jarak minimum
// SetDeviationInPoints(30) = 0.030 USD, terlalu rapat untuk gold saat
// spike sehingga PositionClose gagal justru di saat paling dibutuhkan.
input int    InpCloseSlippagePts   = 100;   // Slippage khusus close basket (points)
input bool   InpDebugExit          = false; // Log rinci keputusan exit

input group  "=== Gate Kedalaman (v1.51) ==="
// Dasar dari analisis MC.xlsx: basket SELL 5 Aug tumbuh jadi 6.41 lot dalam
// 62 menit dan menghabiskan akun. Rekonstruksi ulang basket yang sama
// menunjukkan membekukan ramp lot saat kedalaman >= 3 USD menekan kerugian
// dari -$197 ke -$43, dan ditambah pelebaran step jadi -$32.
//
// Sinyal yang dipakai adalah kedalaman basket sendiri (harga vs BE), BUKAN
// filter displacement/ATR. Alasannya: pada event itu displacement 5 bar
// sesudah anchor mencapai 3.46 USD, jadi filter displacement sebenarnya
// SUDAH menyala - ia hanya tidak menjaga ladder. Kedalaman basket mengukur
// persis apa yang merugikan, tanpa lag dan tanpa normalisasi ATR yang
// justru menelan sinyal saat gerakan berkelanjutan.
// DEFAULT OFF sejak v1.52. Bukti dari dua dataset pada simbol dan tipe akun
// yang sama: tanpa gate, basket 61 posisi / 2,55 lot TUTUP UNTUNG +$235;
// dengan gate, basket 91 posisi / 1,15 lot MENGGANTUNG -$1.143 dan butuh
// retracement 10,19 USD. Sebabnya ramp lot adalah mekanisme perata BE -
// pada ladder yang mengisi ke arah entry yang lebih baik, lot berat di level
// dalam menarik BE mendekati harga sehingga exit terjadi. Membekukan lot
// membuang mekanisme itu. Input tetap disediakan untuk pengujian ulang.
input bool   InpUseDepthLotFreeze  = false; // Bekukan ramp lot saat basket dalam
input double InpLotFreezeDepth     = 3.00;  // Kedalaman pembekuan lot (USD)
input bool   InpUseDepthStepWiden  = false; // Lebarkan step saat basket lebih dalam
input double InpStepWidenDepth     = 5.00;  // Kedalaman pelebaran step (USD)
input double InpStepWidenTo        = 0.50;  // Step setelah dilebarkan (USD)

input group  "=== Hedge Lock (v1.52) ==="
// Asuransi tail. Bukan mekanisme pemulihan: hedge matched MEMBEKUKAN
// kerugian pada besaran saat ia dibuka, tidak pernah memulihkannya.
// Pembuktiannya, tutup slice basket volume v bersama slice hedge volume v
// pada harga P':
//     (P'-E)*v*100 + (P0-P')*v*100 = (P0-E)*v*100
// P' hilang dari rumus, jadi hasilnya hanya bergantung pada selisih entry
// basket dengan harga saat hedge dibuka, dan selalu negatif.
//
// Yang melunasi kerugian beku itu adalah penghasilan normal grid.
//
// Pemicunya JARAK KE RUIN, bukan kedalaman USD:
//     ruin = equity / (volume_basket * uang_per_lot_per_USD)
// Angka ini menyesuaikan diri terhadap ukuran akun DAN volume basket, jadi
// satu nilai berlaku untuk XAUUSDm akun USD maupun XAUUSDc akun cent.
// DEFAULT OFF sejak v1.53. Hedge lock hanya MEMBEKUKAN kerugian, tidak
// menguranginya - lihat pembuktian di atas. Yang menggantikannya adalah
// Recovery Grid di bawah, yang menghasilkan profit NYATA lalu memakainya
// untuk menutup posisi minus, sehingga floating benar-benar berkurang.
// Kalau dinyalakan sementara Recovery juga aktif, keduanya akan
// bertabrakan; OnInit menolak kombinasi itu.
input bool   InpUseHedgeLock        = false;  // Aktifkan hedge lock (usang)
input double InpHedgeRuinDistance   = 150.0;  // Picu saat sisa ruang gerak <= ini (USD)
input double InpHedgeRatio          = 1.00;   // 1.00 = kunci penuh (delta nol)
input double InpHedgeUnwindMult     = 1.10;   // Unwind saat profit >= mult x kerugian beku
input long   InpMagicHedge          = 20263;  // Magic khusus hedge (WAJIB beda)

input group  "=== Recovery Grid (v1.53) ==="
// Basket pemulihan. Bekerja seperti grid biasa EA ini - anchor, ladder,
// BE basket, trailing exit - tapi dengan tiga perbedaan penting:
//
//  1. ARAHNYA TIDAK DIRAMAL. Kalau basket SELL yang rugi, berarti harga
//     sedang naik, jadi recovery-nya BUY. Arah diturunkan dari fakta,
//     bukan dari prediksi. Ini yang membedakannya dari filter tren, yang
//     di MC.xlsx justru membuka SELL tepat di dasar pembalikan.
//
//  2. TARGET PROFITNYA BEDA dan harus JAUH lebih besar dari spread.
//     Spread XAUUSDm terukur 0.24 USD. Satu putaran buka-tutup pada
//     1.89 lot memakan 0.24 x 1.89 x 100 = $45.36. Dengan target 0.30
//     (InpProfitOffset), hasil brutonya $56.70 - 80% dimakan spread dan
//     mekanismenya gagal. Dengan target 2.00, bruto $378 bersih $332.
//
//  3. PROFITNYA DIBELANJAKAN. Saat basket recovery tutup untung, hasilnya
//     langsung dipakai menutup posisi TERBURUK basket yang minus. Volume
//     basket turun, floating turun, dan BE-nya membaik sehingga exit
//     mendekat. Inilah bedanya dengan hedge: floating benar-benar
//     berkurang, bukan hanya beku.
input bool   InpUseRecovery         = false;   // Aktifkan recovery grid
input bool   InpRecoveryTrendGate   = false;   // Stop ladder recovery bila tren melawan arahnya
input double InpRecoveryPosTarget   = 0.50;   // Target profit per POSISI recovery (USD harga, 0=off)
input double InpRecoveryTrigger     = 5000.0; // Picu saat floating basket <= -ini
input double InpRecoveryTarget      = 1.00;   // Target profit recovery (USD harga di atas BE basket)
input double InpRecoveryLotRatio    = 5.0;    // Lot dasar recovery = ratio x InpBaseLot (1.0 = sama dengan grid biasa)
input long   InpMagicRecovBuy       = 20264;  // Magic recovery arah BUY
input long   InpMagicRecovSell      = 20265;  // Magic recovery arah SELL

input group  "=== Arah & Filter ==="
input bool   InpUseBuyGrid     = true;     // Aktifkan grid BUY
input bool   InpUseSellGrid    = true;     // Aktifkan grid SELL
input double InpMaxSpread      = 0;        // Spread maksimum (points, 0=off). XAUUSDc 3-digit: spread normal 150-350

input group  "=== Soft Trend Filter (siklus baru) ==="
input bool            InpUseSoftTrendFilter = true;      // Filter impuls arah (normal = kedua grid aktif)
input ENUM_TIMEFRAMES InpTrendTimeframe      = PERIOD_M1; // Timeframe pembacaan impuls
input int             InpTrendLookback       = 5;         // Jarak displacement (bar tertutup)
input int             InpTrendATRPeriod      = 14;        // Periode ATR internal
input double          InpTrendImpulseATR     = 1.30;      // Minimum displacement dalam ATR
input double          InpTrendMinEfficiency  = 0.60;      // Minimum efficiency ratio (0..1)
input int             InpTrendHoldBars       = 3;         // Tahan arah setelah impuls (bar)

input group  "=== Fast Adverse Trend Gate (anchor + ladder) ==="
// Safety layer independen dari tombol Soft Trend Filter. Tidak menutup posisi
// dan tidak melakukan cut loss: hanya menahan anchor, membatalkan pending,
// serta menghentikan refill arah yang melawan tren sangat kuat.
input bool   InpUseFastTrendGate        = true;  // Gate cepat untuk grid utama + recovery
input int    InpFastTrendWindowSec      = 30;    // Jendela impuls harga live (detik)
input double InpFastTrendImpulseATR     = 0.80;  // Displacement live minimum dalam ATR
input double InpFastTrendMinEfficiency  = 0.70;  // Efficiency live minimum (0..1)
input int    InpFastFillWindowSec       = 60;    // Jendela hitung fill arah sama
input int    InpFastFillCount           = 8;     // Fill minimum untuk burst
input int    InpFastFillGridLevels      = 6;     // Displacement adverse minimum (x GridStep)
input int    InpTrendLatchMinSec        = 45;    // Minimum tetap BLOCKED
input int    InpTrendReleaseQuietSec    = 45;    // Tanpa sinyal adverse sebelum PROBE
input double InpTrendReleaseRetraceATR  = 0.50;  // Retrace dari ekstrem sebelum PROBE
input int    InpTrendProbeCooldownSec   = 10;    // Jarak waktu refill satu-per-satu
input int    InpTrendNormalSec          = 120;   // Tenang sebelum kembali NORMAL

input group  "=== Regime Gate (v1.55) ==="
input bool            InpUseRegimeGate       = true;      // Gate rezim arah (ADX+DI)
input ENUM_TIMEFRAMES InpRegimeTimeframe     = PERIOD_H1; // Timeframe pembacaan rezim
input int             InpRegimeADXPeriod     = 14;        // Periode ADX
input double          InpRegimeADXTrend      = 25.0;      // ADX >= ini => trending (masuk)
input double          InpRegimeADXExit       = 18.0;      // ADX <= ini => sideways (keluar, hysteresis)
input bool            InpRegimeCloseAdverse  = true;      // Tutup basket saat rezim berbalik melawannya

input group  "=== Frontier Placement (ladder anti susul level) ==="
// Disiplin penempatan ladder, independen dari fast gate. Level berikutnya
// tidak pernah di belakang harga berjalan: level yang sudah dilewati harga
// (misal selama BLOCKED fast gate) ditinggalkan, bukan disusul dengan limit
// yang langsung terisi di harga murah. Replay episode tajam MC-B 19 Agt
// (C:\tmp\replay_ftg.py): catch-up refill menumpuk floating pada stop-out
// -18.797 vs -5.722 bila ladder hanya mengisi di depan harga, karena entry
// yang memeluk harga menjaga BE dekat harga berjalan. Bukan cut loss dan
// bukan filter arah: tidak menutup posisi dan tidak menebak tren, hanya
// menolak menambah eksposur di belakang harga.
input bool   InpFrontierPlacement       = true;  // Limit baru selalu di depan harga, level terlewat ditinggalkan

input group  "=== News Filter (siklus baru) ==="
input bool   InpUseNewsFilter       = true;   // Default OFF
input string InpNewsCurrency        = "USD";   // Mata uang berita (XAUUSD: USD)
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH;
input int    InpNewsMinutesBefore   = 30;      // Blokir anchor baru sebelum berita
input int    InpNewsMinutesAfter    = 30;      // Blokir anchor baru setelah berita

input group  "=== Floating Protection ==="
input bool   InpUseFloatingProtection = false;  // Aktif/nonaktif proteksi floating
input double InpMaxFloatingLossPct    = 70.0;  // Maksimum loss EA dalam % equity (blokir anchor baru)

input group  "=== Identitas ==="
input long   InpMagicBuy       = 20261;    // Magic number grid BUY
input long   InpMagicSell      = 20262;    // Magic number grid SELL
input string InpComment        = "CUAN";   // Komentar order

input group  "=== Panel Kontrol & Notifikasi HP ==="
input bool   InpShowPanel      = true;     // Tampilkan panel kontrol di chart
input int    InpNotifyMinutes  = 0;        // Push status ke HP tiap N menit (0=off)

//--- State panel ----------------------------------------------------
//
// Kenapa nilai panel disimpan di variabel sendiri dan tidak langsung
// mengubah input: di MQL5 variabel `input` READ-ONLY selama EA berjalan.
// Jadi setiap hal yang bisa diubah dari panel wajib punya cerminannya di
// sini, dan SELURUH kode runtime harus membacanya lewat accessor Ui*()
// di bawah, bukan lewat input aslinya. Kalau ada satu titik saja yang
// masih membaca input langsung, tombolnya akan terlihat berubah tapi
// perilakunya tidak.
//
// Nilainya disimpan ke GlobalVariable terminal supaya bertahan melewati
// recompile, ganti timeframe, dan restart terminal. Tanpa itu, setiap kali
// chart di-refresh EA kembali ke setelan input dan modul yang sudah Anda
// matikan menyala lagi tanpa pemberitahuan.
bool     g_ui_loaded      = false;
bool     g_ui_ea          = true;
bool     g_ui_fp          = true;
bool     g_ui_news        = false;
bool     g_ui_trend       = true;
bool     g_ui_recov       = true;
bool     g_ui_notify      = false;
double   g_ui_ratio       = 1.0;
datetime g_ui_notif_last  = 0;
datetime g_ui_status_last = 0;
string   g_ui_notif_prev  = "";

string GVUiName(string k) { return "MasTri_" + _Symbol + "_ui_" + k; }

void UiSaveBool(string k, bool v)
{
   GlobalVariableSet(GVUiName(k), v ? 1.0 : 0.0);
}

bool UiLoadBool(string k, bool def)
{
   string g = GVUiName(k);
   if(!GlobalVariableCheck(g)) return def;
   return (GlobalVariableGet(g) > 0.5);
}

void UiLoadState()
{
   if(g_ui_loaded) return;
   // Saat pertama kali (GV belum ada), nilai awal diambil dari input.
   g_ui_ea     = UiLoadBool("ea",     true);
   g_ui_fp     = UiLoadBool("fp",     InpUseFloatingProtection);
   g_ui_news   = UiLoadBool("news",   InpUseNewsFilter);
   g_ui_trend  = UiLoadBool("trend",  InpUseSoftTrendFilter);
   g_ui_recov  = UiLoadBool("recov",  InpUseRecovery);
   g_ui_notify = UiLoadBool("notify", false);
   string gr = GVUiName("ratio");
   g_ui_ratio = GlobalVariableCheck(gr) ? GlobalVariableGet(gr)
                                        : InpRecoveryLotRatio;
   if(g_ui_ratio < 1.0)   g_ui_ratio = 1.0;
   if(g_ui_ratio > 100.0) g_ui_ratio = 100.0;
   g_ui_loaded = true;
}

// Accessor. SELURUH kode runtime membaca lewat sini.
bool   UiEaOn()    { return g_ui_ea;    }
bool   UiFpOn()    { return g_ui_fp;    }
bool   UiNewsOn()  { return g_ui_news;  }
bool   UiTrendOn() { return g_ui_trend; }
bool   UiRecovOn() { return g_ui_recov; }
double UiRatio()   { return g_ui_ratio; }

//--- Globals --------------------------------------------------------
CTrade  trade;
double  g_tick_size  = 0.0;
double  g_point      = 0.0;
int     g_digits     = 0;
double  g_lot_min    = 0.0;
double  g_lot_max    = 0.0;
double  g_lot_step   = 0.0;

// Soft trend state: +1 BUY_ONLY, -1 SELL_ONLY, 0 BOTH.
int      g_trend_state       = 0;
datetime g_last_trend_bar    = 0;
datetime g_trend_hold_until  = 0;
double   g_trend_strength    = 0.0;
double   g_trend_efficiency  = 0.0;

// Cache kalender supaya API MT5 tidak dipanggil pada setiap tick.
bool     g_news_blocked      = false;
datetime g_news_next_check   = 0;
datetime g_news_event_time   = 0;
string   g_news_event_name   = "";
datetime g_last_news_warning = 0;
bool     g_news_tester_warned = false;

// Floating protection bersifat soft-block: tidak dilatch, status dihitung
// ulang tiap tick sehingga EA otomatis aktif lagi saat loss < batas.
bool     g_floating_protection_block = false;
double   g_floating_loss_pct         = 0.0;

// Cache komisi per ticket posisi (komisi entry tidak berubah saat posisi hidup).
ulong    g_comm_ticket[];
double   g_comm_value[];

// State trailing per arah (index 0 = BUY, 1 = SELL).
// Sumber kebenaran SL basket selalu dibaca ulang dari posisi terbuka
// (BasketBestSL) supaya tahan restart; tidak ada cache SL di memori.
datetime g_trail_err_log[BASKET_SLOTS]   = {0, 0, 0, 0};
datetime g_clamp_log[BASKET_SLOTS]       = {0, 0, 0, 0};
bool     g_trail_widen_warn[BASKET_SLOTS] = {false, false, false, false};

// v1.53c: throttle log saat exit dibatalkan karena margin nyata di harga
// kurang dari InpExitMinEdge. Tanpa throttle ini log banjir tiap tick.
datetime g_exit_block_log[BASKET_SLOTS]  = {0, 0, 0, 0};

//--- v1.50: state trailing virtual -----------------------------------
// g_vstop adalah level exit yang sebenarnya dieksekusi EA. Nilainya
// juga dicerminkan ke global variable terminal supaya tahan restart.
double   g_vstop[BASKET_SLOTS]           = {0.0, 0.0, 0.0, 0.0};

// Sedang dalam proses menutup basket. Selama aktif: MaintainLadder
// tidak memasang limit, tidak ada anchor baru, dan CloseBasket diulang
// tiap tick sampai posisi + pending benar-benar bersih.
bool     g_closing[BASKET_SLOTS]         = {false, false, false, false};

// Kandidat SL server terakhir per arah + cooldown kegagalan. Mencegah
// PositionModify dikirim berulang dengan nilai yang sama, dan mencegah
// banjir log saat broker menolak.
double   g_net_last[BASKET_SLOTS]        = {0.0, 0.0, 0.0, 0.0};
double   g_net_fail_val[BASKET_SLOTS]    = {0.0, 0.0, 0.0, 0.0};
ulong    g_net_fail_ticket[BASKET_SLOTS] = {0, 0, 0, 0};
datetime g_net_cool_until[BASKET_SLOTS]  = {0, 0, 0, 0};
// Retcode terakhir yang sudah dilaporkan per arah. Kegagalan dengan
// retcode BARU dilaporkan segera, tidak ikut throttle 60 detik, supaya
// jenis kegagalan yang belum pernah muncul tidak tertelan.
uint     g_net_last_ret[BASKET_SLOTS]    = {0, 0, 0, 0};
datetime g_close_err_log      = 0;

// Broker menolak pemasangan limit (bukan level yang tidak valid).
// Dipakai MaintainLadder untuk menghentikan refill di tick itu.
bool     g_place_reject       = false;
datetime g_place_err_log      = 0;
uint     g_place_last_ret     = 0;
#define  NET_FAIL_COOLDOWN_SEC     5   // gangguan sementara
#define  NET_BLOCKED_COOLDOWN_SEC 60   // izin akun / simbol

// Ringkasan basket yang diadopsi setelah restart dicetak sekali saja.
bool     g_adopt_logged[BASKET_SLOTS]    = {false, false, false, false};

// Adaptive back-off jarak stop. Melebar bertahap hanya saat broker
// benar-benar menolak dengan invalid stops (10016), ada batas atas,
// dan satu baris log per pelebaran.
double   g_stop_pad           = 0.0;
double   g_stop_pad_step      = 0.0;
double   g_stop_pad_max       = 0.0;
bool     g_stop_pad_max_warn  = false;

// Pelebaran berturut-turut tanpa satu pun modify sukses. Kalau melebar
// terus tapi broker tetap menolak, berarti sebabnya BUKAN jarak, dan
// terus melebarkan justru merusak: jarak yang makin lebar membuat clamp
// BE menahan jaring selamanya. Log 6 Aug 08:26-08:37 menunjukkan tepat
// itu - pad naik 0 -> 3.00 dalam 2 menit lalu jaring mati total.
int      g_pad_widen_streak   = 0;
// Diturunkan dari 5 ke 3: pelebaran belum pernah sekali pun menolong di
// broker ini, jadi lebih baik cepat menyerah dan mendiagnosis daripada
// terus melebar sambil mematikan jaring lewat clamp BE.
#define  PAD_WIDEN_STREAK_MAX 3

// Berapa kali sudah menyerah. Tiap penyerahan mencetak spesifikasi
// simbol, dibatasi 3 kali supaya tidak jadi spam tapi juga tidak cuma
// sekali seumur sesi seperti versi sebelumnya.
int      g_giveup_count       = 0;
#define  GIVEUP_REPORT_MAX    3

// Kegagalan jarak yang sudah dilaporkan lengkap. Sepuluh pertama dicetak
// TANPA throttle: satu baris itu harus cukup untuk diagnosis, karena log
// yang sampai ke saya selalu berupa potongan.
int      g_dist_fail_logged   = 0;
#define  DIST_FAIL_LOG_MAX    10

// Maksimum percobaan modify per tick. Mencegah burst pada basket besar,
// tapi tetap mencoba ticket LAIN kalau satu ticket bermasalah - versi
// sebelumnya langsung return sehingga satu ticket rusak bisa membuat
// seluruh basket tidak pernah dapat SL.
#define  NET_ATTEMPTS_PER_TICK 3

// Jaring pengaman dihentikan sementara untuk kedua arah, dipakai saat
// disimpulkan masalahnya bukan jarak.
datetime g_net_giveup_until   = 0;
#define  NET_GIVEUP_SEC       300

// Status clamp BE per arah, supaya pesan "ditahan" dicetak saat status
// BERUBAH, bukan tiap menit selamanya.
bool     g_clamp_active[BASKET_SLOTS]    = {false, false, false, false};

//--- v1.51: gate kedalaman, DILATCH per siklus ------------------------
// Sekali terkunci, tetap terkunci sampai basket tutup. Tanpa latch,
// kedalaman yang berosilasi di sekitar ambang membuat lot berganti-ganti
// antara base dan ramp, dan level yang terisi jadi tidak bisa ditelusuri.
// Latch juga sesuai maksudnya: kalau harga sudah bergerak sejauh itu
// melawan basket, jangan menaikkan eksposur lagi di siklus yang sama.
bool     g_lot_frozen[BASKET_SLOTS]      = {false, false, false, false};
bool     g_step_widened[BASKET_SLOTS]    = {false, false, false, false};
double   g_depth_peak[BASKET_SLOTS]      = {0.0, 0.0, 0.0, 0.0};

//--- Fast adverse-trend gate -----------------------------------------
// State per ARAH ORDER: BUY diblokir saat tren turun sangat kuat, SELL
// diblokir saat tren naik sangat kuat. State ini bukan cut loss dan tidak
// pernah menutup posisi; ia hanya mengendalikan anchor serta pending/refill.
enum ENUM_TREND_GATE_STATE
{
   TREND_GATE_NORMAL  = 0,
   TREND_GATE_BLOCKED = 1,
   TREND_GATE_PROBE   = 2
};

#define FAST_PRICE_SAMPLES 180
#define FAST_FILL_SAMPLES   64

int      g_fast_gate_state[2]       = {TREND_GATE_NORMAL, TREND_GATE_NORMAL};
datetime g_fast_gate_since[2]       = {0, 0};
datetime g_fast_last_adverse[2]     = {0, 0};
double   g_fast_gate_extreme[2]     = {0.0, 0.0};
string   g_fast_gate_reason[2]      = {"", ""};
// Satu cooldown per arah: pada BUY PROBE, grid utama BUY dan RECOV-BUY
// berbagi jatah satu placement; SELL berlaku sama.
datetime g_fast_probe_place[2]      = {0, 0};
bool     g_fast_probe_clean[2]      = {true, true};

datetime g_fast_price_time[FAST_PRICE_SAMPLES];
double   g_fast_price_value[FAST_PRICE_SAMPLES];
int      g_fast_price_count         = 0;

datetime g_fast_fill_time[2][FAST_FILL_SAMPLES];
double   g_fast_fill_price[2][FAST_FILL_SAMPLES];
int      g_fast_fill_head[2]        = {0, 0};
int      g_fast_fill_count[2]       = {0, 0};
int      g_fast_recent_fills[2]     = {0, 0};
double   g_fast_fill_adverse[2]     = {0.0, 0.0};

datetime g_fast_metric_bar         = 0;
double   g_fast_atr                = 0.0;
int      g_fast_slow_state         = 0;
double   g_fast_strength           = 0.0;
double   g_fast_efficiency         = 0.0;
double   g_fast_displacement       = 0.0;

//--- Regime gate (v1.55): rezim pasar dari ADX+DI --------------------
enum ENUM_REGIME_STATE
{
   REGIME_SIDEWAYS = 0,
   REGIME_UP       = 1,
   REGIME_DOWN     = -1
};

ENUM_REGIME_STATE g_regime = REGIME_SIDEWAYS;
// Penanda "sudah ditutup untuk episode rezim ini" per arah (0=BUY, 1=SELL).
// Mencegah penutupan berulang tiap tick selama rezim yang sama tetap aktif.
bool g_regime_closed[2] = {false, false};

//--- v1.52: hedge lock per arah basket -------------------------------
// g_hedge_frozen = total floating (basket + hedge) pada saat hedge dibuka.
// Itulah jumlah yang harus dilunasi penghasilan grid sebelum unwind.
bool     g_hedge_on[2]        = {false, false};
double   g_hedge_frozen[2]    = {0.0, 0.0};
datetime g_hedge_since[2]     = {0, 0};
datetime g_hedge_check[2]     = {0, 0};
bool     g_hedge_logged[2]    = {false, false};
#define  HEDGE_CHECK_SEC      5

int DirIndex(ENUM_POSITION_TYPE dir)
{
   return (dir == POSITION_TYPE_BUY) ? 0 : 1;
}

//+------------------------------------------------------------------+
//| Slot state per BASKET, bukan per arah.                            |
//|                                                                  |
//| Sejak recovery grid ada, satu arah bisa punya DUA basket: grid    |
//| utama dan grid recovery. Kalau state masih diindeks arah, basket  |
//| recovery BUY akan menimpa state grid BUY - vstop, g_closing,      |
//| dedup net, semuanya tertukar. Slot per magic memisahkannya.       |
//|                                                                  |
//|   0 = grid utama BUY     2 = recovery BUY                         |
//|   1 = grid utama SELL    3 = recovery SELL                        |
//+------------------------------------------------------------------+
int SlotOf(long magic)
{
   if(magic == InpMagicBuy)      return 0;
   if(magic == InpMagicSell)     return 1;
   if(magic == InpMagicRecovBuy) return 2;
   return 3;                              // InpMagicRecovSell
}

string BasketName(long magic)
{
   if(magic == InpMagicBuy)      return "BUY";
   if(magic == InpMagicSell)     return "SELL";
   if(magic == InpMagicRecovBuy) return "RECOV-BUY";
   return "RECOV-SELL";
}

// Satu magic hanya boleh memegang satu arah. Ada empat magic grid:
// dua grid utama, dua recovery. Recovery diberi magic terpisah per arah
// supaya seluruh mesin yang sudah ada - anchor GV, vstop GV, ladder,
// BasketBreakEven, trailing - bekerja tanpa perubahan apa pun.
ENUM_POSITION_TYPE DirForMagic(long magic)
{
   if(magic == InpMagicBuy || magic == InpMagicRecovBuy)
      return POSITION_TYPE_BUY;
   return POSITION_TYPE_SELL;
}

bool IsRecoveryMagic(long magic)
{
   return (InpUseRecovery &&
           (magic == InpMagicRecovBuy || magic == InpMagicRecovSell));
}

// Basket recovery arah BUY melayani basket SELL yang rugi, dan sebaliknya.
long RecovMagicFor(ENUM_POSITION_TYPE losing_dir)
{
   return (losing_dir == POSITION_TYPE_BUY) ? InpMagicRecovSell
                                            : InpMagicRecovBuy;
}

ENUM_POSITION_TYPE LosingDirForRecov(long recov_magic)
{
   return (recov_magic == InpMagicRecovBuy) ? POSITION_TYPE_SELL
                                            : POSITION_TYPE_BUY;
}

// Target profit basket. Recovery memakai targetnya sendiri yang jauh lebih
// besar, karena target 0.30 lebih kecil dari biaya spread satu putaran.
double ProfitOffsetFor(long magic)
{
   return IsRecoveryMagic(magic) ? InpRecoveryTarget : InpProfitOffset;
}

// Jumlah posisi ber-magic EA tapi arahnya tidak sesuai magic-nya.
// Dilaporkan sekali supaya kalau ada, kelihatan.
int  g_orphan_warned = 0;

//+------------------------------------------------------------------+
//| Apakah posisi terpilih milik basket magic ini?                    |
//|                                                                  |
//| TIPE POSISI IKUT DIPERIKSA. Tanpa ini, posisi arah lain yang      |
//| kebetulan ber-magic sama akan menerima SL dari sisi yang salah -   |
//| SL di ATAS harga untuk posisi BUY - dan broker menolaknya dengan   |
//| retcode 10016 invalid stops berapa pun jaraknya. Back-off lalu     |
//| melebar terus tanpa pernah menolong.                              |
//|                                                                  |
//| Posisi harus sudah terpilih lewat PositionGetTicket() dulu.        |
//+------------------------------------------------------------------+
bool IsBasketPosition(long magic)
{
   // Hanya magic grid (utama + recovery). Magic hedge memegang dua arah
   // sekaligus, jadi DirForMagic() tidak bermakna untuknya dan ia tidak
   // boleh masuk sini.
   if(magic != InpMagicBuy && magic != InpMagicSell &&
      !IsRecoveryMagic(magic)) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if(PositionGetInteger(POSITION_MAGIC) != magic)   return false;

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   if(type == DirForMagic(magic))
      return true;

   // Arah tidak cocok: bukan milik basket ini. Laporkan sekali.
   if(g_orphan_warned < 3)
   {
      g_orphan_warned++;
      PrintFormat("PERINGATAN: posisi %I64u ber-magic %I64d tapi arahnya %s, "
                  "sedangkan magic itu untuk %s. Posisi ini DIABAIKAN oleh "
                  "pengelola basket. Kemungkinan sisa EA versi lain atau "
                  "order manual dengan magic yang sama.",
                  PositionGetInteger(POSITION_TICKET), magic,
                  EnumToString(type),
                  EnumToString(DirForMagic(magic)));
   }
   return false;
}

// Arah sebagai int untuk fungsi murni di RevEngExit.mqh.
int DirSign(ENUM_POSITION_TYPE dir)
{
   return (dir == POSITION_TYPE_BUY) ? REVEXIT_DIR_BUY : REVEXIT_DIR_SELL;
}

// Nama global variable terminal untuk persistensi anchor (tahan restart)
string GVAnchorName(long magic) { return "MasTri_" + _Symbol + "_" + (string)magic + "_anchor"; }
// Persistensi level trailing virtual, mengikuti pola GVAnchorName().
string GVVStopName(long magic)  { return "MasTri_" + _Symbol + "_" + (string)magic + "_vstop";  }
// Persistensi hedge lock, mengikuti pola yang sama.
string GVHedgeFrozName(long magic)  { return "MasTri_" + _Symbol + "_" + (string)magic + "_hfroz";  }
string GVHedgeSinceName(long magic) { return "MasTri_" + _Symbol + "_" + (string)magic + "_hsince"; }
string GVFloatingLockName()
{
   return "MT_FP_" + _Symbol + "_" + (string)InpMagicBuy +
          "_" + (string)InpMagicSell;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // State panel dimuat PALING AWAL supaya semua laporan OnInit di bawah
   // menampilkan nilai yang benar-benar berlaku, bukan nilai input yang
   // mungkin sudah di-override dari panel pada sesi sebelumnya.
   UiLoadState();

   g_tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_lot_min   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_lot_max   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_lot_step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(g_tick_size <= 0.0 || g_point <= 0.0)
   {
      Print("Gagal membaca spesifikasi simbol ", _Symbol);
      return INIT_FAILED;
   }

   if(InpProfitOffset <= 0.0 || InpSLBuffer < 0.0 ||
      InpTrailingDistance <= 0.0 || InpTrailingStep < 0.0 ||
      InpExitEdgePerPos < 0.0)
   {
      Print("Parameter exit tidak valid. Pastikan ProfitOffset dan "
            "TrailingDistance > 0 serta Buffer/TrailingStep/EdgePerPos >= 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if((InpUseSoftTrendFilter || InpUseFastTrendGate) &&
      (InpTrendLookback < 2 || InpTrendATRPeriod < 2 ||
       InpTrendImpulseATR <= 0.0 ||
       InpTrendMinEfficiency < 0.0 || InpTrendMinEfficiency > 1.0 ||
       InpTrendHoldBars < 0))
   {
      Print("Parameter soft trend filter tidak valid.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseFastTrendGate &&
      (InpFastTrendWindowSec < 5 ||
       InpFastTrendWindowSec >= FAST_PRICE_SAMPLES ||
       InpFastTrendImpulseATR <= 0.0 ||
       InpFastTrendMinEfficiency < 0.0 ||
       InpFastTrendMinEfficiency > 1.0 ||
       InpFastFillWindowSec < 5 || InpFastFillCount < 2 ||
       InpFastFillCount > FAST_FILL_SAMPLES ||
       InpFastFillGridLevels < 1 ||
       InpTrendLatchMinSec < 0 || InpTrendReleaseQuietSec < 1 ||
       InpTrendReleaseRetraceATR < 0.0 ||
       InpTrendProbeCooldownSec < 1 ||
       InpTrendNormalSec < InpTrendReleaseQuietSec * 2 +
                           InpTrendProbeCooldownSec))
   {
      Print("Parameter Fast Adverse Trend Gate tidak valid.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseNewsFilter &&
      (StringLen(InpNewsCurrency) == 0 ||
       InpNewsMinutesBefore < 0 || InpNewsMinutesAfter < 0 ||
       (InpNewsMinutesBefore == 0 && InpNewsMinutesAfter == 0)))
   {
      Print("Parameter news filter tidak valid.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseFloatingProtection &&
      (InpMaxFloatingLossPct <= 0.0 || InpMaxFloatingLossPct > 100.0))
   {
      Print("Floating protection harus > 0 dan <= 100 persen.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpNetMinDistance < 0.0 || InpNetSpreadMult < 0.0 ||
      InpCloseSlippagePts <= 0)
   {
      Print("Parameter eksekusi exit tidak valid. NetMinDistance dan "
            "NetSpreadMult harus >= 0, CloseSlippagePts harus > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!InpUseVirtualTrailing && !InpUseSafetyNetSL)
   {
      Print("Trailing virtual dan jaring pengaman SL dua-duanya OFF: "
            "basket tidak akan pernah mengambil profit.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseDepthLotFreeze && InpLotFreezeDepth <= 0.0)
   {
      Print("InpLotFreezeDepth harus > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseDepthStepWiden &&
      (InpStepWidenDepth <= 0.0 || InpStepWidenTo < InpGridStep))
   {
      Print("Gate step tidak valid: StepWidenDepth harus > 0 dan "
            "StepWidenTo tidak boleh lebih kecil dari InpGridStep.");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Gate step melangkahi nomor level, jadi ramp lot akan naik lebih cepat
   // per fill kalau ia masih aktif. Mensyaratkan gate lot menyala lebih
   // dulu membuat interaksi itu aman secara konstruksi.
   if(InpUseDepthStepWiden && InpUseDepthLotFreeze &&
      InpStepWidenDepth < InpLotFreezeDepth)
   {
      Print("InpStepWidenDepth harus >= InpLotFreezeDepth, supaya ramp lot "
            "sudah dibekukan sebelum step dilebarkan.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseDepthStepWiden && !InpUseDepthLotFreeze)
      Print("PERINGATAN: gate step aktif tanpa gate lot. Karena pelebaran "
            "step melangkahi nomor level, ramp lot akan naik lebih cepat "
            "per fill - kebalikan dari yang diinginkan. Nyalakan "
            "InpUseDepthLotFreeze.");

   if(InpMagicBuy == InpMagicSell)
   {
      Print("InpMagicBuy dan InpMagicSell tidak boleh sama: satu magic "
            "hanya boleh memegang satu arah basket.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseRecovery)
   {
      long m[4] = {InpMagicBuy, InpMagicSell, InpMagicRecovBuy,
                   InpMagicRecovSell};
      for(int a = 0; a < 4; a++)
         for(int b = a + 1; b < 4; b++)
            if(m[a] == m[b])
            {
               Print("Keempat magic (BUY, SELL, RecovBUY, RecovSELL) wajib "
                     "berbeda satu sama lain.");
               return INIT_PARAMETERS_INCORRECT;
            }
      if(InpRecoveryTrigger <= 0.0)
      {
         Print("InpRecoveryTrigger harus > 0.");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpRecoveryLotRatio <= 0.0)
      {
         Print("InpRecoveryLotRatio harus > 0.");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpRecoveryPosTarget < 0.0)
      {
         Print("InpRecoveryPosTarget tidak boleh negatif "
               "(0 = matikan exit per-posisi). Nilai negatif berarti "
               "menutup posisi dalam keadaan rugi, dan EA ini tanpa cut loss.");
         return INIT_PARAMETERS_INCORRECT;
      }
      // Target recovery harus melebihi biaya spread satu putaran, kalau
      // tidak mekanismenya kehilangan uang tiap siklus.
      double spr = SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(spr > 0.0 && InpRecoveryTarget <= spr * 2.0)
         PrintFormat("PERINGATAN: InpRecoveryTarget %.2f terlalu dekat "
                     "dengan spread %.3f. Sebagian besar hasil tiap siklus "
                     "akan dimakan spread. Sarankan minimal %.2f.",
                     InpRecoveryTarget, spr, spr * 4.0);
   }

   if(InpUseRecovery && InpUseHedgeLock)
   {
      Print("InpUseRecovery dan InpUseHedgeLock tidak boleh aktif bersamaan: "
            "keduanya membuka posisi arah berlawanan dan akan bertabrakan. "
            "Recovery mengurangi floating, hedge hanya membekukannya - "
            "pilih satu.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseHedgeLock)
   {
      if(InpMagicHedge == InpMagicBuy || InpMagicHedge == InpMagicSell)
      {
         Print("InpMagicHedge WAJIB berbeda dari magic grid. Kalau sama, "
               "BasketBreakEven ikut menghitung kaki hedge dan seluruh "
               "logika exit rusak.");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpHedgeRuinDistance <= 0.0)
      {
         Print("InpHedgeRuinDistance harus > 0.");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpHedgeRatio <= 0.0 || InpHedgeRatio > 1.0)
      {
         Print("InpHedgeRatio harus > 0 dan <= 1.00. Di atas 1.00 posisinya "
               "bukan terkunci lagi tapi berbalik arah.");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpHedgeUnwindMult < 1.0)
      {
         Print("InpHedgeUnwindMult harus >= 1.00, kalau tidak unwind terjadi "
               "sebelum kerugian bekunya tertutup.");
         return INIT_PARAMETERS_INCORRECT;
      }
   }

   if(!InpUseVirtualTrailing)
      Print("PERINGATAN: InpUseVirtualTrailing OFF. Mode ini mereplikasi "
            "v1.43 untuk pembanding backtest: SL server jadi eksekutor, "
            "TANPA clamp BE, jadi SL bisa jatuh di bawah breakeven basket. "
            "Jangan dipakai di akun live.");

   // Back-off jarak stop: naik setengah NetMinDistance per penolakan,
   // minimal satu tick, dengan batas atas 6x NetMinDistance supaya tidak
   // melebar tanpa henti kalau masalahnya bukan jarak.
   g_stop_pad          = 0.0;
   g_stop_pad_step     = MathMax(InpNetMinDistance * 0.5, g_tick_size);
   g_stop_pad_max      = MathMax(InpNetMinDistance * 6.0, g_tick_size * 10.0);
   g_stop_pad_max_warn = false;

   // Versi lama melatch proteksi lewat global variable. Proteksi sekarang
   // bersifat soft-block dan dievaluasi ulang tiap tick, jadi sisa kunci
   // dari versi sebelumnya dibersihkan agar tidak menyesatkan.
   string floating_lock = GVFloatingLockName();
   if(GlobalVariableCheck(floating_lock))
   {
      GlobalVariableDel(floating_lock);
      Print("Kunci floating protection lama dihapus: proteksi kini hanya "
            "menahan siklus baru dan lepas otomatis saat loss turun.");
   }
   g_floating_protection_block = false;
   g_floating_loss_pct         = 0.0;

   // Akun harus hedge agar grid buy & sell bisa paralel
   ENUM_ACCOUNT_MARGIN_MODE mm =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(InpUseBuyGrid && InpUseSellGrid && mm != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("PERINGATAN: akun bukan mode hedging; grid dua arah tidak bisa paralel.");

   trade.SetDeviationInPoints(DEFAULT_DEVIATION_PTS);
   trade.SetAsyncMode(false);

   DumpSymbolSpec();

   // Rekonsiliasi sebelum tick pertama: pulihkan level virtual dari GV
   // atau dari SL server yang masih menempel di basket.
   ReconcileBasket(POSITION_TYPE_BUY,  InpMagicBuy);
   ReconcileBasket(POSITION_TYPE_SELL, InpMagicSell);

   UiLoadState();
   UiBuildPanel();
   PrintFormat("Panel : %s. Notif HP: %s%s. Toggle tersimpan di GlobalVariable "
               "jadi bertahan melewati restart.",
               InpShowPanel ? "ON" : "OFF",
               g_ui_notify ? "ON" : "OFF",
               (InpNotifyMinutes > 0)
                  ? StringFormat(", status berkala tiap %d menit",
                                 InpNotifyMinutes)
                  : "");
   if(!g_ui_ea)
      Print("PERHATIAN: panel dalam keadaan EA JEDA dari sesi sebelumnya. "
            "Tidak ada anchor/level baru sampai tombol EA ditekan lagi.");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Nama mode filling yang didukung broker (bitmask).                 |
//+------------------------------------------------------------------+
string FillingModeText()
{
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   string s = "";
   if((mode & SYMBOL_FILLING_FOK) != 0) s += "FOK ";
   if((mode & SYMBOL_FILLING_IOC) != 0) s += "IOC ";
   if((mode & SYMBOL_FILLING_BOC) != 0) s += "BOC ";
   if(StringLen(s) == 0) s = "(tidak dilaporkan) ";
   return StringFormat("%s[mask %d]", s, (int)mode);
}

//+------------------------------------------------------------------+
//| Dump spesifikasi simbol. Basis kalibrasi InpNetMinDistance dan     |
//| InpNetSpreadMult, dan satu-satunya cara memastikan skala uang      |
//| simbol yang sedang dipakai. XAUUSDc (akun cent) dan XAUUSDm (akun  |
//| standar) berbeda sampai 100x pada lot yang sama, jadi angka hasil  |
//| forward test di satu simbol tidak boleh dibawa mentah ke simbol    |
//| lain tanpa membandingkan baris SKALA UANG di bawah.                |
//+------------------------------------------------------------------+
void DumpSymbolSpec()
{
   long   stops   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long   spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spr_abs = (ask > 0.0 && bid > 0.0) ? (ask - bid) : 0.0;

   PrintFormat("=== EA Grid v%s : spesifikasi %s ===",
               EA_VERSION, _Symbol);
   PrintFormat("digits %d | point %s | tick size %s | lot %.2f/%.2f step %.2f",
               g_digits,
               DoubleToString(g_point, 8),
               DoubleToString(g_tick_size, 8),
               g_lot_min, g_lot_max, g_lot_step);

   // SKALA UANG. Ini yang membedakan akun cent (XAUUSDc) dari akun standar
   // (XAUUSDm) sampai 100x pada lot yang sama. Tanpa baris ini, angka
   // drawdown dari forward test di satu simbol mudah disalahartikan saat
   // dibawa ke simbol lain.
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double contract  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double per_usd   = (g_tick_size > 0.0) ? tick_val * (1.0 / g_tick_size)
                                          : 0.0;
   string acc_ccy   = AccountInfoString(ACCOUNT_CURRENCY);
   PrintFormat("SKALA UANG: 1.00 lot bergerak 1.00 USD harga = %s %s "
               "| contract size %s | tick value %s",
               DoubleToString(per_usd, 2), acc_ccy,
               DoubleToString(contract, 2),
               DoubleToString(tick_val, 5));
   PrintFormat("Akun: %s | balance %s | equity %s | leverage 1:%d | "
               "free margin %s",
               acc_ccy,
               DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
               DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
               (int)AccountInfoInteger(ACCOUNT_LEVERAGE),
               DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
   if(per_usd > 0.0)
      PrintFormat("Ekuivalen risiko: basket %.2f lot yang terbenam 25.00 USD "
                  "= %s %s floating.",
                  1.0, DoubleToString(25.0 * per_usd, 2), acc_ccy);
   PrintFormat("Stops level %d (%s USD) | Freeze level %d (%s USD)",
               (int)stops, DoubleToString(stops * g_point, g_digits),
               (int)freeze, DoubleToString(freeze * g_point, g_digits));
   PrintFormat("Spread %d points (%s USD) | filling mode: %s",
               (int)spread, DoubleToString(spr_abs, g_digits),
               FillingModeText());
   PrintFormat("Jarak minimum DILAPORKAN broker : %s USD  <- formula v1.43",
               DoubleToString(ReportedMinStopDistance(), g_digits));
   PrintFormat("Jarak minimum HASIL HITUNG      : %s USD "
               "[max(stops, freeze, spread x %.2f, NetMinDistance %.2f, tick)]",
               DoubleToString(EffectiveMinStopDistance(), g_digits),
               InpNetSpreadMult, InpNetMinDistance);
   PrintFormat("Jarak yang DIPAKAI jalur exit   : %s USD  <- mode %s",
               DoubleToString(ExitMinStopDistance(), g_digits),
               InpUseVirtualTrailing ? "hybrid v1.50" : "baseline v1.43");
   PrintFormat("KALIBRASI: kalau 'dilaporkan' jauh lebih kecil dari "
               "'hasil hitung', broker memang menegakkan minimum dinamis. "
               "Sesuaikan InpNetMinDistance / InpNetSpreadMult dari angka ini.");
   PrintFormat("Back-off: langkah %s USD, batas atas %s USD",
               DoubleToString(g_stop_pad_step, g_digits),
               DoubleToString(g_stop_pad_max, g_digits));
   PrintFormat("Exit: virtual trailing %s | jaring pengaman SL %s | "
               "slippage close %d pts (%s USD)",
               InpUseVirtualTrailing ? "ON" : "OFF (baseline v1.43)",
               InpUseSafetyNetSL ? "ON" : "OFF",
               InpCloseSlippagePts,
               DoubleToString(InpCloseSlippagePts * g_point, g_digits));
   PrintFormat("Rumus exit (tidak berubah dari v1.43): arming di BE +/- %.2f "
               "ditambah buffer %.2f | trailing %.2f | step %.2f",
               InpProfitOffset, InpSLBuffer,
               InpTrailingDistance, InpTrailingStep);
   PrintFormat("Ramp lot: base %.2f, flat %d level, +base tiap %d level. "
               "Level 21 di %.2f USD dari anchor, level 61 di %.2f USD.",
               NormLot(InpBaseLot), InpLevelsFlat, InpLevelsPerStep,
               InpGridStep * 20.0, InpGridStep * 60.0);
   if(InpUseFastTrendGate)
      PrintFormat("Fast trend gate: ON, live %ds/%.2fATR/ER%.2f | burst %d fill "
                  "dalam %ds + %d level | latch %ds, quiet %ds, retrace %.2fATR, "
                  "probe 1 order/%ds. TANPA CUT LOSS.",
                  InpFastTrendWindowSec, InpFastTrendImpulseATR,
                  InpFastTrendMinEfficiency, InpFastFillCount,
                  InpFastFillWindowSec, InpFastFillGridLevels,
                  InpTrendLatchMinSec, InpTrendReleaseQuietSec,
                  InpTrendReleaseRetraceATR, InpTrendProbeCooldownSec);
   else
      Print("Fast trend gate: OFF");

   if(InpUseDepthLotFreeze)
      PrintFormat("Gate lot  : ON, ramp dibekukan saat kedalaman >= %.2f USD",
                  InpLotFreezeDepth);
   else
      Print("Gate lot  : OFF (ramp berjalan penuh sampai berapa pun dalam)");
   if(InpUseDepthStepWiden)
      PrintFormat("Gate step : ON, step %.2f -> %.2f saat kedalaman >= %.2f USD "
                  "(stride %d level)",
                  InpGridStep, InpStepWidenTo, InpStepWidenDepth,
                  (int)MathMax(1.0, MathRound(InpStepWidenTo / InpGridStep)));
   else
      Print("Gate step : OFF");

   double per_lot = MoneyPerUsdPerLot();
   if(InpUseHedgeLock)
   {
      PrintFormat("Hedge lock: ON, picu saat ruin <= %.1f USD, rasio %.2f, "
                  "unwind di %.2fx kerugian beku, magic %I64d",
                  InpHedgeRuinDistance, InpHedgeRatio,
                  InpHedgeUnwindMult, InpMagicHedge);
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(per_lot > 0.0 && InpHedgeRuinDistance > 0.0)
         PrintFormat("  -> pada equity %s %s, hedge menyala saat volume "
                     "basket mencapai %.2f lot",
                     DoubleToString(eq, 2), acc_ccy,
                     eq / (InpHedgeRuinDistance * per_lot));
      PrintFormat("  margin hedged: %s (0 = margin dihitung dari eksposur "
                  "NET, jadi hedge matched hampir tidak memakai margin)",
                  DoubleToString(
                     SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_HEDGED), 2));
   }
   else
      Print("Hedge lock: OFF (usang, digantikan Recovery Grid)");

   if(InpUseRecovery)
   {
      double spr = SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);
      // Yang dicetak adalah ratio EFEKTIF (UiRatio), bukan input, karena
      // panel bisa sudah mengubahnya di sesi sebelumnya dan nilainya
      // bertahan lewat GlobalVariable.
      PrintFormat("Recovery : ON, picu saat floating basket <= -%.2f %s, "
                  "target %.2f USD, lot dasar %s (ratio %.0f x InpBaseLot %s)"
                  ", magic %I64d/%I64d",
                  InpRecoveryTrigger, acc_ccy, InpRecoveryTarget,
                  DoubleToString(NormLot(InpBaseLot * UiRatio()), 2),
                  UiRatio(), DoubleToString(InpBaseLot, 2),
                  InpMagicRecovBuy, InpMagicRecovSell);
      if(MathAbs(UiRatio() - InpRecoveryLotRatio) > 1e-8)
         PrintFormat("  CATATAN: ratio dari PANEL (%.0f) berbeda dari input "
                     "(%.0f). Panel yang berlaku. Tekan tombol lot di panel "
                     "untuk mengubah, bukan dialog Inputs.",
                     UiRatio(), InpRecoveryLotRatio);
      if(InpRecoveryPosTarget > 0.0)
         PrintFormat("  EXIT PER-POSISI: ON, target %.2f USD per posisi "
                     "(bersih setelah spread; harga perlu bergerak %.2f dari "
                     "entry). Berjalan berdampingan dengan exit basket "
                     "BE+%.2f, mana yang lebih dulu. Laba tiap posisi yang "
                     "lepas langsung masuk dompet dan mencicil basket minus.",
                     InpRecoveryPosTarget, InpRecoveryPosTarget + spr,
                     InpRecoveryTarget);
      else
         Print("  EXIT PER-POSISI: OFF (InpRecoveryPosTarget = 0). Dompet "
               "hanya terisi bila basket recovery tutup UTUH di BE+target.");
      PrintFormat("  spread sekarang %.3f USD. Biaya spread per putaran = "
                  "spread x lot x %.0f. Target %.2f harus jauh di atas itu.",
                  spr, MoneyPerUsdPerLot(), InpRecoveryTarget);
      PrintFormat("  CATATAN SATUAN: ambang %.2f dalam %s. Di akun cent, "
                  "%.2f %s = $%.2f - pastikan ini yang Anda maksud.",
                  InpRecoveryTrigger, acc_ccy, InpRecoveryTrigger, acc_ccy,
                  InpRecoveryTrigger / 100.0);
   }
   else
      Print("Recovery : OFF");
   Print("=================================================");
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Anchor DAN level trailing virtual sengaja dibiarkan di global
   // variables. Itu yang membuat siklus lanjut dari level yang sama
   // setelah EA di-remove lalu di-attach ulang, tanpa arming ulang.
   // Pembersihannya dilakukan ClearCycleState() saat basket kosong.
   //
   // Objek panel HARUS dibersihkan, kalau tidak ia tertinggal di chart
   // sebagai objek mati yang tidak bisa diklik setelah EA dilepas. State
   // toggle-nya tetap di GlobalVariable, jadi tidak ada yang hilang.
   UiDestroyPanel();
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      ShowStatus("DIBLOKIR: Algo Trading nonaktif (cek tombol Algo Trading & izin EA)");
      return;
   }
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
   {
      ShowStatus("DIBLOKIR: market tutup / simbol tidak bisa ditradingkan");
      return;
   }

   // Floating protection tidak lagi menutup posisi. Nilainya hanya
   // dipakai sebagai salah satu filter izin anchor baru di bawah.
   bool floating_block = CheckFloatingProtection();

   UpdateSoftTrendFilter();
   UpdateFastTrendGate();
   UpdateRegime();

   bool spread_ok   = SpreadOK();
   bool news_block  = IsNewsBlocked();
   // UiEaOn() = tombol EA di panel. Saat JEDA, tidak ada anchor baru dan
   // MaintainLadder juga menolak level baru, tapi basket yang sudah ada
   // tetap dikelola sampai exit. Menutup paksa berarti merealisasi kerugian.
   bool allow_buy   = UiEaOn() && InpUseBuyGrid  && spread_ok && !news_block &&
                      !floating_block && TrendAllows(POSITION_TYPE_BUY) &&
                      FastGateAllowsAnchor(POSITION_TYPE_BUY, InpMagicBuy) &&
                      RegimeAllowsBuy();
   bool allow_sell  = UiEaOn() && InpUseSellGrid && spread_ok && !news_block &&
                      !floating_block && TrendAllows(POSITION_TYPE_SELL) &&
                      FastGateAllowsAnchor(POSITION_TYPE_SELL, InpMagicSell) &&
                      RegimeAllowsSell();

   if(!spread_ok)
   {
      static datetime last_warn = 0;
      if(TimeCurrent() - last_warn >= 300) // log tiap 5 menit
      {
         PrintFormat("Spread %d points > MaxSpread %.0f -> anchor baru ditahan. "
                     "Basket aktif tetap dikelola.",
                     (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), InpMaxSpread);
         last_warn = TimeCurrent();
      }
   }

   // Regime close-adverse: tutup basket yang rezimnya berbalik melawannya.
   // Hanya sekali per episode rezim. Pending sisi terblokir dibersihkan oleh
   // ManageGrid (STATE IDLE membatalkan pending saat tidak ada posisi).
   if(InpUseRegimeGate && InpRegimeCloseAdverse)
   {
      if(g_regime == REGIME_UP)
      {
         if(!g_regime_closed[1])
         {
            g_regime_closed[1] = true;
            if(CountPositions(InpMagicSell) > 0)
            {
               g_closing[SlotOf(InpMagicSell)] = true;
               PrintFormat("REGIME UP: menutup basket SELL (melawan tren naik).");
            }
         }
      }
      else
         g_regime_closed[1] = false;

      if(g_regime == REGIME_DOWN)
      {
         if(!g_regime_closed[0])
         {
            g_regime_closed[0] = true;
            if(CountPositions(InpMagicBuy) > 0)
            {
               g_closing[SlotOf(InpMagicBuy)] = true;
               PrintFormat("REGIME DOWN: menutup basket BUY (melawan tren turun).");
            }
         }
      }
      else
         g_regime_closed[0] = false;
   }

   // Selalu panggil kedua pengelola agar basket lama tidak terlantar
   // ketika input arah, spread, trend, atau news menahan siklus baru.
   ManageGrid(POSITION_TYPE_BUY,  InpMagicBuy,  allow_buy);
   ManageGrid(POSITION_TYPE_SELL, InpMagicSell, allow_sell);

   // Recovery grid: mekanika sama, magic dan target profit sendiri.
   // Recovery BUY melayani basket SELL yang rugi, dan sebaliknya. Izin
   // siklus barunya datang dari kondisi basket yang dilayani, bukan dari
   // filter arah - arahnya sudah ditentukan fakta basket mana yang rugi.
   if(InpUseRecovery)
   {
      ManageGrid(POSITION_TYPE_BUY,  InpMagicRecovBuy,
                 RecoveryAllowed(POSITION_TYPE_SELL));
      ManageGrid(POSITION_TYPE_SELL, InpMagicRecovSell,
                 RecoveryAllowed(POSITION_TYPE_BUY));
      // Exit per-posisi dijalankan SETELAH ManageGrid, supaya kalau basket
      // recovery sudah masuk mode closing utuh, ia yang menang dan exit
      // per-posisi tidak ikut campur di tengah likuidasi.
      CloseRecoveryWinners(InpMagicRecovBuy);
      CloseRecoveryWinners(InpMagicRecovSell);
   }

   // Back-off jarak stop tidak diwarisi siklus berikutnya.
   MaybeResetStopPad();

   // Hedge lock dimatikan tapi masih ada kaki hedge sisa dari versi
   // sebelumnya: tutup sekali supaya tidak jadi posisi arah yang terlantar.
   if(!InpUseHedgeLock)
   {
      static bool swept = false;
      if(!swept)
      {
         double h = HedgeVolume(POSITION_TYPE_BUY) +
                    HedgeVolume(POSITION_TYPE_SELL);
         if(h > 0.0)
         {
            PrintFormat("Hedge lock OFF tapi masih ada %.2f lot kaki hedge "
                        "sisa. Ditutup sekarang supaya tidak terlantar "
                        "sebagai posisi arah.", h);
            CloseHedge(POSITION_TYPE_BUY);
            CloseHedge(POSITION_TYPE_SELL);
         }
         swept = true;
      }
   }

   string state = "AKTIF";
   if(floating_block)
      state = "FLOATING PROTECTION: PENDING DIBATALKAN, ANCHOR BARU DITAHAN";
   else if(!spread_ok)
      state = "ANCHOR BARU DIBLOKIR: SPREAD";
   else if(news_block)
      state = "ANCHOR BARU DIBLOKIR: NEWS";
   else if(!allow_buy && !allow_sell)
      state = "MENUNGGU IZIN ARAH";

   ShowStatus(state);
}

//+------------------------------------------------------------------+
//| Catat setiap deal masuk untuk mendeteksi burst fill per arah.     |
//| Hanya DEAL_ENTRY_IN yang dihitung; penutupan posisi tidak boleh    |
//| dibaca sebagai fill baru dan tidak pernah memicu gate.             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!InpUseFastTrendGate || trans.type != TRADE_TRANSACTION_DEAL_ADD ||
      trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_IN) return;

   long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(!IsGridMagic(magic)) return;

   datetime when =
      (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   if(when <= 0) when = TimeCurrent();
   double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   RecordFastFill(DirForMagic(magic), when, price);
}

//+------------------------------------------------------------------+
//| Status di pojok chart supaya mudah dipantau                      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| PANEL KONTROL                                                    |
//|                                                                  |
//| CATATAN PENTING soal "dashboard mobile":                          |
//|                                                                  |
//| Panel ini objek chart di terminal DESKTOP. Aplikasi MT5 di HP      |
//| terhubung ke SERVER BROKER, bukan ke terminal Anda, jadi objek     |
//| chart dan Comment() tidak pernah ikut terkirim ke HP. Tidak ada    |
//| cara membuat tombol yang bisa ditekan dari aplikasi MT5 mobile -   |
//| MT5 mobile tidak menjalankan MQL5 sama sekali.                    |
//|                                                                  |
//| Yang benar-benar sampai ke HP hanya SendNotification() di UiNotify |
//| di bawah. Itu jalur SATU ARAH (EA -> HP) dan butuh MetaQuotes ID   |
//| diisi di terminal: Tools > Options > Notifications.                |
//|                                                                  |
//| Yang JUGA terlihat di HP tanpa usaha tambahan: daftar posisi dan   |
//| pending order beserta komentarnya, karena itu disinkronkan lewat   |
//| server broker. Itu sebabnya komentar order dibuat "CUAN" - itulah  |
//| penanda yang Anda lihat di layar HP.                              |
//+------------------------------------------------------------------+
#define UI_PFX  "EAG_"
#define UI_MRG  10
#define UI_TOP  18
#define UI_W    172
#define UI_H    20
#define UI_GAP  2

void UiNotify(string msg)
{
   if(!g_ui_notify) return;
   if(MQLInfoInteger(MQL_TESTER)) return;   // tidak ada push di tester
   // Notifikasi identik yang berulang tidak berguna, dan server membatasi
   // laju pengiriman. Dua penjaga: jeda minimum, dan tolak duplikat.
   if(msg == g_ui_notif_prev && TimeCurrent() - g_ui_notif_last < 300)
      return;
   if(TimeCurrent() - g_ui_notif_last < 5)
      return;
   if(SendNotification(StringFormat("[EA Grid %s] %s", _Symbol, msg)))
   {
      g_ui_notif_last = TimeCurrent();
      g_ui_notif_prev = msg;
   }
}

void UiObj(string name, ENUM_OBJECT type, int xdist, int ydist,
           int w, int h)
{
   string n = UI_PFX + name;
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, type, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_ZORDER, 100);
      ObjectSetString(0, n, OBJPROP_FONT, "Tahoma");
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 8);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, xdist);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, ydist);
   if(type == OBJ_BUTTON)
   {
      ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   }
}

void UiBtn(string name, int row, string text, bool on,
           int xdist = -1, int w = UI_W)
{
   if(xdist < 0) xdist = UI_MRG + w;
   UiObj(name, OBJ_BUTTON, xdist, UI_TOP + row * (UI_H + UI_GAP), w, UI_H);
   string n = UI_PFX + name;
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, on ? C'0,110,70' : C'135,40,40');
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, n, OBJPROP_STATE, false);
}

void UiLbl(string name, int row, string text, color c)
{
   UiObj(name, OBJ_LABEL, UI_MRG, UI_TOP + row * (UI_H + UI_GAP), 0, 0);
   string n = UI_PFX + name;
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
}

void UiBuildPanel()
{
   if(!InpShowPanel) return;
   UiLoadState();
   int r = 0;
   UiLbl("L_TITLE", r++, StringFormat("EA Grid v%s  %s", EA_VERSION, _Symbol),
         clrGold);
   UiBtn("B_EA",    r++, g_ui_ea    ? "EA: AKTIF" : "EA: JEDA (tak buka baru)",
         g_ui_ea);
   UiBtn("B_FP",    r++, g_ui_fp    ? "Floating Prot: ON" : "Floating Prot: OFF",
         g_ui_fp);
   UiBtn("B_NEWS",  r++, g_ui_news  ? "News Filter: ON"   : "News Filter: OFF",
         g_ui_news);
   UiBtn("B_TREND", r++, g_ui_trend ? "Trend Filter: ON"  : "Trend Filter: OFF",
         g_ui_trend);
   UiBtn("B_RECOV", r++, g_ui_recov ? "Recovery: ON"      : "Recovery: OFF",
         g_ui_recov);
   // Baris lot recovery:  [ - ]  lot 0.05  [ + ]
   int wsm  = 30;
   int wmid = UI_W - 2 * wsm;
   UiBtn("B_RMIN",  r, "-", true, UI_MRG + UI_W, wsm);
   UiBtn("B_RVAL",  r, StringFormat("Lot rec %s",
                                    DoubleToString(InpBaseLot * g_ui_ratio, 2)),
         true, UI_MRG + wsm + wmid, wmid);
   ObjectSetInteger(0, UI_PFX + "B_RVAL", OBJPROP_BGCOLOR, C'55,55,60');
   UiBtn("B_RPLUS", r, "+", true, UI_MRG + wsm, wsm);
   r++;
   UiBtn("B_NOTIF", r++, g_ui_notify ? "Notif HP: ON" : "Notif HP: OFF",
         g_ui_notify);
   ChartRedraw();
}

void UiDestroyPanel()
{
   ObjectsDeleteAll(0, UI_PFX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Klik tombol panel.                                                |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam, UI_PFX) != 0) return;
   string k    = StringSubstr(sparam, StringLen(UI_PFX));
   string what = "";
   if(k == "B_EA")
   {
      g_ui_ea = !g_ui_ea; UiSaveBool("ea", g_ui_ea);
      what = g_ui_ea ? "EA AKTIF kembali"
                     : "EA JEDA: tidak buka anchor/level baru, "
                       "posisi & exit yang ada tetap dikelola";
   }
   else if(k == "B_FP")
   {
      g_ui_fp = !g_ui_fp; UiSaveBool("fp", g_ui_fp);
      what = StringFormat("Floating protection %s", g_ui_fp ? "ON" : "OFF");
   }
   else if(k == "B_NEWS")
   {
      g_ui_news = !g_ui_news; UiSaveBool("news", g_ui_news);
      what = StringFormat("News filter %s", g_ui_news ? "ON" : "OFF");
   }
   else if(k == "B_TREND")
   {
      g_ui_trend = !g_ui_trend; UiSaveBool("trend", g_ui_trend);
      what = StringFormat("Trend filter %s (juga dipakai gate tren recovery)",
                          g_ui_trend ? "ON" : "OFF");
   }
   else if(k == "B_RECOV")
   {
      g_ui_recov = !g_ui_recov; UiSaveBool("recov", g_ui_recov);
      // Sengaja hanya menahan siklus BARU. Basket recovery yang sudah jalan
      // tetap dikelola sampai exit, karena menutupnya paksa berarti
      // merealisasi kerugian.
      what = StringFormat("Recovery %s (siklus baru; episode berjalan tetap "
                          "dikelola sampai exit)", g_ui_recov ? "ON" : "OFF");
   }
   else if(k == "B_NOTIF")
   {
      g_ui_notify = !g_ui_notify; UiSaveBool("notify", g_ui_notify);
      what = StringFormat("Notifikasi HP %s", g_ui_notify ? "ON" : "OFF");
   }
   else if(k == "B_RMIN" || k == "B_RPLUS")
   {
      g_ui_ratio += (k == "B_RPLUS") ? 1.0 : -1.0;
      if(g_ui_ratio < 1.0)   g_ui_ratio = 1.0;
      if(g_ui_ratio > 100.0) g_ui_ratio = 100.0;
      GlobalVariableSet(GVUiName("ratio"), g_ui_ratio);
      // Lot dasar recovery ditetapkan sekali per episode dan disimpan di GV,
      // jadi perubahan ini berlaku untuk episode BERIKUTNYA, bukan yang
      // sedang berjalan.
      what = StringFormat("Lot recovery -> %s (ratio %.0f x %s). "
                          "Berlaku untuk episode berikutnya.",
                          DoubleToString(InpBaseLot * g_ui_ratio, 2),
                          g_ui_ratio, DoubleToString(InpBaseLot, 2));
   }
   else return;
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   UiBuildPanel();
   PrintFormat("PANEL: %s", what);
   UiNotify(what);
}

void ShowStatus(string state)
{
   string trend_text = "OFF";
   if(UiTrendOn())
   {
      string direction = "BOTH";
      if(g_trend_state > 0) direction = "BUY_ONLY";
      if(g_trend_state < 0) direction = "SELL_ONLY";
      trend_text = StringFormat("%s %.2fATR ER%.2f",
                                direction, g_trend_strength,
                                g_trend_efficiency);
   }

   string news_text = "OFF";
   if(UiNewsOn())
   {
      if(MQLInfoInteger(MQL_TESTER))
         news_text = "N/A TESTER";
      else if(g_news_blocked)
         news_text = StringFormat("%s @ %s", g_news_event_name,
                                  TimeToString(g_news_event_time,
                                               TIME_DATE|TIME_MINUTES));
      else
         news_text = "CLEAR";
   }

   string floating_text = "OFF";
   if(UiFpOn())
   {
      floating_text = StringFormat("OK %.2f/%.2f%% eq",
                                   g_floating_loss_pct,
                                   InpMaxFloatingLossPct);
      if(g_floating_protection_block)
         floating_text = StringFormat("BLOCK %.2f/%.2f%% eq",
                                      g_floating_loss_pct,
                                      InpMaxFloatingLossPct);
   }

   string txt = StringFormat(
      "EA Grid v%s | %s\nTrend: %s | News: %s\n"
      "Fast Gate: %s\nFloating Protection: %s\n"
      "Spread: %d pts | Buy pos: %d pend: %d | Sell pos: %d pend: %d\n"
      "Exit BUY : %s\nExit SELL: %s\n%s",
      EA_VERSION, state,
      trend_text, news_text,
      FastGateStatusText(), floating_text,
      (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
      CountPositions(InpMagicBuy),  CountPendings(InpMagicBuy),
      CountPositions(InpMagicSell), CountPendings(InpMagicSell),
      TrailStatusText(POSITION_TYPE_BUY,  InpMagicBuy),
      TrailStatusText(POSITION_TYPE_SELL, InpMagicSell),
      RecoveryStatusText());
   Comment(txt);

   // Panel disegarkan di sini juga supaya label lot recovery ikut berubah
   // kalau ratio diubah, dan warna tombol tetap sinkron setelah recompile.
   UiBuildPanel();

   // Push status berkala ke HP. Ini satu-satunya cara isi panel sampai ke
   // aplikasi mobile, karena objek chart tidak pernah disinkronkan ke sana.
   if(InpNotifyMinutes > 0 && g_ui_notify && !MQLInfoInteger(MQL_TESTER) &&
      TimeCurrent() - g_ui_status_last >= (long)InpNotifyMinutes * 60)
   {
      g_ui_status_last = TimeCurrent();
      double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      SendNotification(StringFormat(
         "[EA Grid %s] %s | eq %.2f bal %.2f float %.2f | "
         "BUY %d pos SELL %d pos | rec lot %s",
         _Symbol, g_ui_ea ? "AKTIF" : "JEDA", eq, bal, eq - bal,
         CountPositions(InpMagicBuy), CountPositions(InpMagicSell),
         DoubleToString(InpBaseLot * g_ui_ratio, 2)));
   }
}

//+------------------------------------------------------------------+
//| Ringkasan exit untuk panel. Level virtual (eksekutor) ditampilkan  |
//| bersebelahan dengan SL server (jaring pengaman) supaya selisih     |
//| jarak keduanya langsung kelihatan.                                |
//+------------------------------------------------------------------+
string TrailStatusText(ENUM_POSITION_TYPE dir, long magic)
{
   int idx = SlotOf(magic);

   if(CountPositions(magic) == 0)
      return g_closing[idx] ? "CLOSING (menunggu bersih)" : "IDLE";

   double price = (dir == POSITION_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   string vs = "VSTOP -";
   if(g_vstop[idx] > 0.0)
      vs = StringFormat("VSTOP %s (%.2f)",
                        DoubleToString(g_vstop[idx], g_digits),
                        MathAbs(price - g_vstop[idx]));

   bool   has_sl = false;
   double net    = BasketBestSL(dir, magic, has_sl);
   string ns = "NET -";
   if(has_sl)
      ns = StringFormat("NET %s (%.2f)", DoubleToString(net, g_digits),
                        MathAbs(price - net));

   string prefix = "";
   if(g_closing[idx])
      prefix = "CLOSING | ";
   else if(g_vstop[idx] <= 0.0)
      prefix = "WAIT ARM | ";

   // Status gate kedalaman: puncak kedalaman siklus ini + latch yang aktif.
   string gate = "";
   if(g_depth_peak[idx] > 0.0)
   {
      gate = StringFormat(" | dalam %.2f", g_depth_peak[idx]);
      if(g_lot_frozen[idx])   gate += " LOT-BEKU";
      if(g_step_widened[idx]) gate += " STEP-LEBAR";
   }

   // Volume basket + jarak ruin. Dua angka yang paling menentukan
   // keselamatan. Saat terkunci hedge, ruin dihitung dari eksposur NET
   // supaya angkanya jujur: volume basket boleh tumbuh terus, tapi kalau
   // net-nya nol maka equity tidak bergerak dan ruin praktis tak terbatas.
   double bvol = BasketVolume(magic);
   if(bvol > 0.0)
   {
      double expo = g_hedge_on[idx] ? MathAbs(NetExposureLots()) : bvol;
      double r    = RuinDistance(expo);
      gate += StringFormat(" | %.2f lot ruin %s", bvol,
                           (r >= DBL_MAX / 2.0) ? "~"
                                                : StringFormat("%.0f", r));
   }
   if(g_hedge_on[idx])
      gate += StringFormat(" | HEDGE %.2f beku %.2f net %.2f",
                           HedgeVolume(HedgeTypeFor(dir)),
                           g_hedge_frozen[idx], NetExposureLots());

   return prefix + vs + " | " + ns + gate;
}

//+------------------------------------------------------------------+
//| Baris panel untuk recovery grid.                                  |
//+------------------------------------------------------------------+
string RecoveryStatusText()
{
   if(!UiRecovOn())
      return "Recovery: OFF";

   string s = "";
   long lm[2] = {InpMagicBuy, InpMagicSell};
   for(int i = 0; i < 2; i++)
   {
      double lflt = BasketFloating(lm[i]);
      long   rm   = RecovMagicFor(DirForMagic(lm[i]));
      int    rn   = CountPositions(rm);
      if(rn == 0 && lflt > -InpRecoveryTrigger)
         continue;
      if(StringLen(s) > 0) s += "  ";
      s += StringFormat("%s flt %.0f/-%.0f", BasketName(lm[i]),
                        lflt, InpRecoveryTrigger);
      if(rn > 0)
         s += StringFormat(" -> %s %d pos %.2f lot flt %.0f",
                           BasketName(rm), rn, BasketVolume(rm),
                           BasketFloating(rm));
   }
   if(StringLen(s) == 0)
      return "Recovery: siaga";
   return "Recovery: " + s;
}

//+------------------------------------------------------------------+
//| Filter spread                                                    |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   if(InpMaxSpread <= 0)
      return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= (long)InpMaxSpread);
}

//+------------------------------------------------------------------+
//| Apakah magic number termasuk grid yang dikelola EA ini?          |
//+------------------------------------------------------------------+
bool IsManagedMagic(long magic)
{
   // Magic hedge ikut dihitung: ia bagian dari eksposur EA, dan floating
   // protection harus melihat total yang sudah terkunci, bukan hanya sisi
   // basket yang merugi.
   return (magic == InpMagicBuy || magic == InpMagicSell ||
           IsRecoveryMagic(magic) ||
           (InpUseHedgeLock && magic == InpMagicHedge));
}

// Magic grid saja, tanpa hedge.
bool IsGridMagic(long magic)
{
   return (magic == InpMagicBuy || magic == InpMagicSell ||
           IsRecoveryMagic(magic));
}

//+------------------------------------------------------------------+
//| Komisi posisi. POSITION_COMMISSION sudah deprecated di MT5 build  |
//| baru (selalu 0) karena komisi dibebankan pada deal, jadi nilainya |
//| diambil dari deal pembuka posisi. Hasil dicache per ticket:       |
//| komisi entry tidak berubah selama posisi masih hidup.             |
//| PENTING: posisi harus sudah terpilih (PositionGetTicket) sebelum  |
//| fungsi ini dipanggil.                                            |
//+------------------------------------------------------------------+
double ManagedPositionCommission(ulong ticket)
{
   int total = ArraySize(g_comm_ticket);
   for(int i = 0; i < total; i++)
      if(g_comm_ticket[i] == ticket)
         return g_comm_value[i];

   double commission = 0.0;
   long   pos_id     = PositionGetInteger(POSITION_IDENTIFIER);
   if(HistorySelectByPosition(pos_id))
   {
      int deals = HistoryDealsTotal();
      for(int d = 0; d < deals; d++)
      {
         ulong deal = HistoryDealGetTicket(d);
         if(deal == 0) continue;
         commission += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      }
   }

   ArrayResize(g_comm_ticket, total + 1);
   ArrayResize(g_comm_value,  total + 1);
   g_comm_ticket[total] = ticket;
   g_comm_value[total]  = commission;
   return commission;
}

//+------------------------------------------------------------------+
//| Buang cache komisi untuk ticket yang sudah tidak terbuka lagi.    |
//+------------------------------------------------------------------+
void PruneCommissionCache()
{
   int total = ArraySize(g_comm_ticket);
   if(total == 0) return;

   int keep = 0;
   for(int i = 0; i < total; i++)
   {
      if(!PositionSelectByTicket(g_comm_ticket[i]))
         continue;
      g_comm_ticket[keep] = g_comm_ticket[i];
      g_comm_value[keep]  = g_comm_value[i];
      keep++;
   }
   if(keep != total)
   {
      ArrayResize(g_comm_ticket, keep);
      ArrayResize(g_comm_value,  keep);
   }
}

//+------------------------------------------------------------------+
//| Floating P/L gabungan grid BUY+SELL pada simbol ini.             |
//| Termasuk swap dan komisi agar angka setara biaya riil basket.    |
//+------------------------------------------------------------------+
double ManagedFloatingProfit()
{
   double result = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!IsManagedMagic(PositionGetInteger(POSITION_MAGIC))) continue;

      result += PositionGetDouble(POSITION_PROFIT);
      result += PositionGetDouble(POSITION_SWAP);
      result += ManagedPositionCommission(ticket);
   }
   return result;
}

//+------------------------------------------------------------------+
//| Soft block: jika floating loss EA mencapai % equity, hanya posisi |
//| baru yang ditahan. Basket berjalan TIDAK ditutup dan trailing     |
//| tetap aktif. Status dihitung ulang tiap tick sehingga EA otomatis |
//| membuka siklus lagi ketika rasio loss turun di bawah batas.       |
//+------------------------------------------------------------------+
bool CheckFloatingProtection()
{
   if(!UiFpOn())
   {
      g_floating_protection_block = false;
      g_floating_loss_pct         = 0.0;
      return false;
   }

   PruneCommissionCache();

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double floating = ManagedFloatingProfit();
   g_floating_loss_pct =
      (equity > 0.0 && floating < 0.0)
      ? (-floating / equity) * 100.0
      : 0.0;

   // Equity <= 0 berarti akun sudah tidak punya penyangga: selalu blokir.
   bool block = (equity <= 0.0)
                ? (floating < 0.0)
                : (g_floating_loss_pct >= InpMaxFloatingLossPct);

   if(block != g_floating_protection_block)
   {
      if(block)
         PrintFormat("FLOATING PROTECTION AKTIF: loss %.2f%% >= %.2f%% equity. "
                     "Semua limit pending dibatalkan, posisi terbuka tetap "
                     "dikelola trailing.",
                     g_floating_loss_pct, InpMaxFloatingLossPct);
      else
         PrintFormat("FLOATING PROTECTION LEPAS: loss %.2f%% < %.2f%% equity. "
                     "EA boleh membuka posisi baru dan ladder dilanjutkan.",
                     g_floating_loss_pct, InpMaxFloatingLossPct);
      g_floating_protection_block = block;
   }

   return g_floating_protection_block;
}

//+------------------------------------------------------------------+
//| Soft direction filter berbasis displacement/ATR dan efficiency   |
//| ratio. Filter diperbarui hanya sekali per bar timeframe filter.   |
//+------------------------------------------------------------------+
void UpdateSoftTrendFilter()
{
   if(!UiTrendOn())
   {
      g_trend_state      = 0;
      g_trend_strength   = 0.0;
      g_trend_efficiency = 0.0;
      return;
   }

   datetime current_bar = iTime(_Symbol, InpTrendTimeframe, 0);
   if(current_bar <= 0 || current_bar == g_last_trend_bar)
      return;
   g_last_trend_bar = current_bar;

   int bars_needed = MathMax(InpTrendLookback + 1,
                             InpTrendATRPeriod + 1);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpTrendTimeframe, 1,
                          bars_needed, rates);
   if(copied < bars_needed)
   {
      // Fail-open: data indikator belum siap tidak boleh membekukan grid.
      g_trend_state      = 0;
      g_trend_strength   = 0.0;
      g_trend_efficiency = 0.0;
      return;
   }

   double displacement = rates[0].close -
                         rates[InpTrendLookback].close;
   double path = 0.0;
   for(int i = 0; i < InpTrendLookback; i++)
      path += MathAbs(rates[i].close - rates[i + 1].close);

   double tr_sum = 0.0;
   for(int i = 0; i < InpTrendATRPeriod; i++)
   {
      double previous_close = rates[i + 1].close;
      double tr = MathMax(rates[i].high - rates[i].low,
                  MathMax(MathAbs(rates[i].high - previous_close),
                          MathAbs(rates[i].low  - previous_close)));
      tr_sum += tr;
   }

   double atr = tr_sum / (double)InpTrendATRPeriod;
   g_trend_strength   = (atr  > 0.0) ? MathAbs(displacement) / atr : 0.0;
   g_trend_efficiency = (path > 0.0) ? MathAbs(displacement) / path : 0.0;

   datetime now = TimeCurrent();
   bool strong_impulse =
      (g_trend_strength   >= InpTrendImpulseATR &&
       g_trend_efficiency >= InpTrendMinEfficiency);

   if(strong_impulse)
   {
      g_trend_state = (displacement > 0.0) ? 1 : -1;
      int seconds_per_bar = PeriodSeconds(InpTrendTimeframe);
      if(seconds_per_bar <= 0) seconds_per_bar = 60;
      g_trend_hold_until = current_bar +
                           InpTrendHoldBars * seconds_per_bar;
   }
   else if(now >= g_trend_hold_until)
   {
      g_trend_state = 0;
   }
}

//+------------------------------------------------------------------+
//| Apakah arah boleh membuka siklus/anchor baru?                    |
//+------------------------------------------------------------------+
bool TrendAllows(ENUM_POSITION_TYPE dir)
{
   if(!UiTrendOn() || g_trend_state == 0)
      return true;
   if(dir == POSITION_TYPE_BUY)
      return (g_trend_state > 0);
   return (g_trend_state < 0);
}

//+------------------------------------------------------------------+
//| Fast adverse-trend gate. Safety layer ini INDEPENDEN dari tombol  |
//| soft trend. Ia tidak menutup posisi dan tidak mengubah basket exit;|
//| yang dikendalikan hanya anchor serta pending/refill order masuk.  |
//+------------------------------------------------------------------+
string FastGateStateName(int state)
{
   if(state == TREND_GATE_BLOCKED) return "BLOCKED";
   if(state == TREND_GATE_PROBE)   return "PROBE";
   return "NORMAL";
}

bool FastGateApplies(long magic)
{
   if(!InpUseFastTrendGate) return false;
   if(magic == InpMagicBuy || magic == InpMagicSell) return true;
   if(IsRecoveryMagic(magic)) return InpRecoveryTrendGate;
   return false;
}

bool FastGateAllowsAnchor(ENUM_POSITION_TYPE dir, long magic)
{
   if(!FastGateApplies(magic)) return true;
   // Anchor baru ditahan selama BLOCKED dan PROBE. PROBE disediakan hanya
   // untuk melanjutkan ladder basket lama satu order per cooldown.
   return (g_fast_gate_state[DirIndex(dir)] == TREND_GATE_NORMAL);
}

bool FastGateBlocksPending(ENUM_POSITION_TYPE dir, long magic)
{
   return (FastGateApplies(magic) &&
           g_fast_gate_state[DirIndex(dir)] == TREND_GATE_BLOCKED);
}

int FastGatePendingTarget(ENUM_POSITION_TYPE dir, long magic)
{
   if(!FastGateApplies(magic)) return InpPendingBatch;
   int state = g_fast_gate_state[DirIndex(dir)];
   if(state == TREND_GATE_BLOCKED) return 0;
   if(state == TREND_GATE_PROBE)   return 1;
   return InpPendingBatch;
}

int FastGateRefillCount(ENUM_POSITION_TYPE dir, long magic)
{
   if(!FastGateApplies(magic)) return InpBatchRefill;
   int state = g_fast_gate_state[DirIndex(dir)];
   if(state == TREND_GATE_BLOCKED) return 0;
   if(state == TREND_GATE_PROBE)   return 1;
   return InpBatchRefill;
}

bool FastGateProbeReady(ENUM_POSITION_TYPE dir, long magic)
{
   if(!FastGateApplies(magic) ||
      g_fast_gate_state[DirIndex(dir)] != TREND_GATE_PROBE)
      return true;
   int di = DirIndex(dir);
   return (TimeCurrent() - g_fast_probe_place[di] >=
           InpTrendProbeCooldownSec);
}

void FastGateMarkProbePlacement(ENUM_POSITION_TYPE dir, long magic)
{
   if(FastGateApplies(magic) &&
      g_fast_gate_state[DirIndex(dir)] == TREND_GATE_PROBE)
      g_fast_probe_place[DirIndex(dir)] = TimeCurrent();
}

bool FastGatePrepareProbe(ENUM_POSITION_TYPE dir)
{
   int di = DirIndex(dir);
   if(!InpUseFastTrendGate ||
      g_fast_gate_state[di] != TREND_GATE_PROBE)
      return true;
   if(g_fast_probe_clean[di])
      return true;

   // Sapu KEDUA basket searah sebagai satu unit. Tidak boleh ada RECOV-BUY
   // memasang probe saat pending BUY utama belum bersih, atau sebaliknya.
   long main_magic = (dir == POSITION_TYPE_BUY) ? InpMagicBuy : InpMagicSell;
   long rec_magic  = (dir == POSITION_TYPE_BUY) ? InpMagicRecovBuy
                                                : InpMagicRecovSell;
   CancelAllPendings(main_magic);
   if(InpUseRecovery && InpRecoveryTrendGate)
      CancelAllPendings(rec_magic);

   int left = CountPendings(main_magic);
   if(InpUseRecovery && InpRecoveryTrendGate)
      left += CountPendings(rec_magic);
   if(left > 0)
      return false; // cancel parsial: ulangi tick berikutnya sampai nol

   g_fast_probe_clean[di] = true;
   // Setelah benar-benar nol, tunggu satu cooldown penuh sebelum placement
   // probe pertama. Caller tetap return pada tick pembersihan ini.
   g_fast_probe_place[di] = TimeCurrent();
   PrintFormat("FAST TREND GATE %s PROBE CLEAN: seluruh pending utama + "
               "recovery searah sudah nol. Placement pertama menunggu %d detik.",
               (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL",
               InpTrendProbeCooldownSec);
   return false;
}

void AddFastPriceSample(datetime now, double price)
{
   if(price <= 0.0) return;
   if(g_fast_price_count > 0 &&
      g_fast_price_time[g_fast_price_count - 1] == now)
   {
      g_fast_price_value[g_fast_price_count - 1] = price;
      return;
   }

   if(g_fast_price_count < FAST_PRICE_SAMPLES)
   {
      g_fast_price_time[g_fast_price_count]  = now;
      g_fast_price_value[g_fast_price_count] = price;
      g_fast_price_count++;
      return;
   }

   for(int i = 1; i < FAST_PRICE_SAMPLES; i++)
   {
      g_fast_price_time[i - 1]  = g_fast_price_time[i];
      g_fast_price_value[i - 1] = g_fast_price_value[i];
   }
   g_fast_price_time[FAST_PRICE_SAMPLES - 1]  = now;
   g_fast_price_value[FAST_PRICE_SAMPLES - 1] = price;
}

void UpdateFastClosedMetrics()
{
   datetime current_bar = iTime(_Symbol, InpTrendTimeframe, 0);
   if(current_bar <= 0 || current_bar == g_fast_metric_bar)
      return;

   int bars_needed = MathMax(InpTrendLookback + 1,
                             InpTrendATRPeriod + 1);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpTrendTimeframe, 1,
                          bars_needed, rates);
   if(copied < bars_needed)
   {
      g_fast_atr        = 0.0;
      g_fast_slow_state = 0;
      return; // coba lagi tick berikutnya; jangan fail-open permanen satu bar
   }
   g_fast_metric_bar = current_bar;

   double displacement = rates[0].close -
                         rates[InpTrendLookback].close;
   double path = 0.0;
   for(int i = 0; i < InpTrendLookback; i++)
      path += MathAbs(rates[i].close - rates[i + 1].close);

   double tr_sum = 0.0;
   for(int i = 0; i < InpTrendATRPeriod; i++)
   {
      double previous_close = rates[i + 1].close;
      double tr = MathMax(rates[i].high - rates[i].low,
                  MathMax(MathAbs(rates[i].high - previous_close),
                          MathAbs(rates[i].low  - previous_close)));
      tr_sum += tr;
   }
   g_fast_atr = tr_sum / (double)InpTrendATRPeriod;

   double strength = (g_fast_atr > 0.0)
                     ? MathAbs(displacement) / g_fast_atr : 0.0;
   double efficiency = (path > 0.0)
                       ? MathAbs(displacement) / path : 0.0;
   bool strong = (strength >= InpTrendImpulseATR &&
                  efficiency >= InpTrendMinEfficiency);
   g_fast_slow_state = strong ? ((displacement > 0.0) ? 1 : -1) : 0;
}

void UpdateFastLiveMetrics(datetime now)
{
   g_fast_displacement = 0.0;
   g_fast_strength     = 0.0;
   g_fast_efficiency   = 0.0;
   if(g_fast_price_count < 2 || g_fast_atr <= 0.0)
      return;

   int first = g_fast_price_count - 1;
   datetime cutoff = now - InpFastTrendWindowSec;
   while(first > 0 && g_fast_price_time[first - 1] >= cutoff)
      first--;
   if(first >= g_fast_price_count - 1)
      return;

   int last = g_fast_price_count - 1;
   double path = 0.0;
   for(int i = first + 1; i <= last; i++)
      path += MathAbs(g_fast_price_value[i] - g_fast_price_value[i - 1]);

   g_fast_displacement = g_fast_price_value[last] -
                         g_fast_price_value[first];
   g_fast_strength = MathAbs(g_fast_displacement) / g_fast_atr;
   g_fast_efficiency = (path > 0.0)
                       ? MathAbs(g_fast_displacement) / path : 0.0;
}

void RecordFastFill(ENUM_POSITION_TYPE dir, datetime when, double price)
{
   int di = DirIndex(dir);
   int at = g_fast_fill_head[di];
   g_fast_fill_time[di][at]  = when;
   g_fast_fill_price[di][at] = price;
   g_fast_fill_head[di] = (at + 1) % FAST_FILL_SAMPLES;
   if(g_fast_fill_count[di] < FAST_FILL_SAMPLES)
      g_fast_fill_count[di]++;
}

void UpdateFastFillMetrics(ENUM_POSITION_TYPE dir, datetime now, double mid)
{
   int di = DirIndex(dir);
   int recent = 0;
   datetime oldest_time = 0;
   double oldest_price = 0.0;
   for(int k = 0; k < g_fast_fill_count[di]; k++)
   {
      int at = g_fast_fill_head[di] - 1 - k;
      while(at < 0) at += FAST_FILL_SAMPLES;
      datetime ft = g_fast_fill_time[di][at];
      // Jangan mengasumsikan event transaksi selalu tiba kronologis. Deal
      // lama yang datang terlambat dilewati, bukan menghentikan scan ring.
      if(ft <= 0 || now - ft < 0 || now - ft > InpFastFillWindowSec)
         continue;
      recent++;
      if(oldest_time == 0 || ft < oldest_time)
      {
         oldest_time  = ft;
         oldest_price = g_fast_fill_price[di][at];
      }
   }

   g_fast_recent_fills[di] = recent;
   if(oldest_price <= 0.0)
   {
      g_fast_fill_adverse[di] = 0.0;
      return;
   }
   double adverse = (dir == POSITION_TYPE_BUY)
                    ? (oldest_price - mid) : (mid - oldest_price);
   g_fast_fill_adverse[di] = MathMax(0.0, adverse);
}

void SetFastGateBlocked(ENUM_POSITION_TYPE dir, string reason,
                        datetime now, double mid)
{
   int di = DirIndex(dir);
   bool changed = (g_fast_gate_state[di] != TREND_GATE_BLOCKED);
   g_fast_gate_state[di]   = TREND_GATE_BLOCKED;
   g_fast_last_adverse[di] = now;
   g_fast_gate_reason[di]  = reason;
   g_fast_probe_clean[di]  = false;

   if(changed)
   {
      g_fast_gate_since[di]   = now;
      g_fast_gate_extreme[di] = mid;
      PrintFormat("FAST TREND GATE %s -> BLOCKED: %s. Live %.2fATR ER%.2f, "
                  "fill %d/%ds adverse %.2f. Pending arah ini dibatalkan; "
                  "posisi terbuka tetap dipegang, TANPA CUT LOSS.",
                  (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL", reason,
                  g_fast_strength, g_fast_efficiency,
                  g_fast_recent_fills[di], InpFastFillWindowSec,
                  g_fast_fill_adverse[di]);
   }
   else if(dir == POSITION_TYPE_SELL)
      g_fast_gate_extreme[di] = MathMax(g_fast_gate_extreme[di], mid);
   else
      g_fast_gate_extreme[di] = (g_fast_gate_extreme[di] <= 0.0)
                                ? mid : MathMin(g_fast_gate_extreme[di], mid);
}

void UpdateFastGateDirection(ENUM_POSITION_TYPE dir, bool adverse,
                             string reason, datetime now, double mid)
{
   int di = DirIndex(dir);
   int state = g_fast_gate_state[di];

   if(adverse)
   {
      SetFastGateBlocked(dir, reason, now, mid);
      return;
   }

   if(state == TREND_GATE_NORMAL)
      return;

   // Ekstrem terus mengikuti arah adverse walau sinyal cepat sedang tenang.
   if(dir == POSITION_TYPE_SELL)
      g_fast_gate_extreme[di] = MathMax(g_fast_gate_extreme[di], mid);
   else
      g_fast_gate_extreme[di] = (g_fast_gate_extreme[di] <= 0.0)
                                ? mid : MathMin(g_fast_gate_extreme[di], mid);

   long quiet_for = now - g_fast_last_adverse[di];
   if(state == TREND_GATE_BLOCKED)
   {
      if(now - g_fast_gate_since[di] < InpTrendLatchMinSec ||
         quiet_for < InpTrendReleaseQuietSec)
         return;

      double retrace = (dir == POSITION_TYPE_SELL)
                       ? (g_fast_gate_extreme[di] - mid)
                       : (mid - g_fast_gate_extreme[di]);
      double need = g_fast_atr * InpTrendReleaseRetraceATR;
      bool retraced   = (need <= 0.0 || retrace >= need);
      bool long_quiet = (quiet_for >= (long)InpTrendReleaseQuietSec * 2);
      if(!retraced && !long_quiet)
         return;

      g_fast_gate_state[di] = TREND_GATE_PROBE;
      g_fast_probe_clean[di] = false;
      PrintFormat("FAST TREND GATE %s -> PROBE: tenang %d detik, retrace %.2f "
                  "(butuh %.2f). Ladder lama boleh lanjut satu order per %d "
                  "detik; anchor baru tetap ditahan.",
                  (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL",
                  (int)quiet_for, retrace, need, InpTrendProbeCooldownSec);
      return;
   }

   // PROBE kembali NORMAL hanya setelah cukup lama tanpa sinyal adverse.
   if(state == TREND_GATE_PROBE && quiet_for >= InpTrendNormalSec)
   {
      g_fast_gate_state[di]  = TREND_GATE_NORMAL;
      g_fast_gate_reason[di] = "";
      g_fast_probe_clean[di] = true;
      PrintFormat("FAST TREND GATE %s -> NORMAL: %d detik tanpa impuls adverse. "
                  "Anchor dan refill batch normal aktif kembali.",
                  (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL",
                  (int)quiet_for);
   }
}

void UpdateFastTrendGate()
{
   if(!InpUseFastTrendGate)
   {
      g_fast_gate_state[0] = TREND_GATE_NORMAL;
      g_fast_gate_state[1] = TREND_GATE_NORMAL;
      return;
   }

   datetime now = TimeCurrent();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(now <= 0 || bid <= 0.0 || ask <= 0.0) return;
   double mid = (bid + ask) * 0.5;

   AddFastPriceSample(now, mid);
   UpdateFastClosedMetrics();
   UpdateFastLiveMetrics(now);
   UpdateFastFillMetrics(POSITION_TYPE_BUY,  now, mid);
   UpdateFastFillMetrics(POSITION_TYPE_SELL, now, mid);

   bool fast_strong = (g_fast_strength >= InpFastTrendImpulseATR &&
                       g_fast_efficiency >= InpFastTrendMinEfficiency);
   bool fast_up   = fast_strong && g_fast_displacement > 0.0;
   bool fast_down = fast_strong && g_fast_displacement < 0.0;

   double burst_distance = InpFastFillGridLevels * InpGridStep;
   bool buy_burst = (g_fast_recent_fills[DirIndex(POSITION_TYPE_BUY)] >=
                     InpFastFillCount &&
                     g_fast_fill_adverse[DirIndex(POSITION_TYPE_BUY)] >=
                     burst_distance);
   bool sell_burst = (g_fast_recent_fills[DirIndex(POSITION_TYPE_SELL)] >=
                      InpFastFillCount &&
                      g_fast_fill_adverse[DirIndex(POSITION_TYPE_SELL)] >=
                      burst_distance);

   bool block_buy  = (g_fast_slow_state < 0 || fast_down || buy_burst);
   bool block_sell = (g_fast_slow_state > 0 || fast_up   || sell_burst);

   string buy_reason = "";
   if(g_fast_slow_state < 0) buy_reason = "tren M1 turun kuat";
   if(fast_down) buy_reason += (StringLen(buy_reason) > 0 ? " + " : "") +
                               "impuls live turun";
   if(buy_burst) buy_reason += (StringLen(buy_reason) > 0 ? " + " : "") +
                               "burst fill BUY adverse";

   string sell_reason = "";
   if(g_fast_slow_state > 0) sell_reason = "tren M1 naik kuat";
   if(fast_up) sell_reason += (StringLen(sell_reason) > 0 ? " + " : "") +
                              "impuls live naik";
   if(sell_burst) sell_reason += (StringLen(sell_reason) > 0 ? " + " : "") +
                                 "burst fill SELL adverse";

   UpdateFastGateDirection(POSITION_TYPE_BUY,  block_buy,  buy_reason,  now, mid);
   UpdateFastGateDirection(POSITION_TYPE_SELL, block_sell, sell_reason, now, mid);
}

string FastGateStatusText()
{
   if(!InpUseFastTrendGate) return "OFF";
   return StringFormat("BUY %s | SELL %s | live %.2fATR ER%.2f | fill %d/%d",
      FastGateStateName(g_fast_gate_state[DirIndex(POSITION_TYPE_BUY)]),
      FastGateStateName(g_fast_gate_state[DirIndex(POSITION_TYPE_SELL)]),
      g_fast_strength, g_fast_efficiency,
      g_fast_recent_fills[DirIndex(POSITION_TYPE_BUY)],
      g_fast_recent_fills[DirIndex(POSITION_TYPE_SELL)]);
}

//+------------------------------------------------------------------+
//| Regime gate: ADX+DI menentukan rezim UP / DOWN / SIDEWAYS.        |
//| Dibaca dari bar tertutup terakhir (shift 1) supaya tidak repaint. |
//| Hysteresis: masuk trending di InpRegimeADXTrend, keluar di        |
//| InpRegimeADXExit.                                                 |
//+------------------------------------------------------------------+
void UpdateRegime()
{
   if(!InpUseRegimeGate)
   {
      g_regime = REGIME_SIDEWAYS;
      g_regime_closed[0] = false;
      g_regime_closed[1] = false;
      return;
   }

   int h = iADX(_Symbol, InpRegimeTimeframe, InpRegimeADXPeriod);
   if(h == INVALID_HANDLE)
      return;

   double adx[1], dip[1], dim[1];
   int got_adx = CopyBuffer(h, 0, 1, 1, adx);
   int got_dip = CopyBuffer(h, 1, 1, 1, dip);
   int got_dim = CopyBuffer(h, 2, 1, 1, dim);
   IndicatorRelease(h);
   if(got_adx < 1 || got_dip < 1 || got_dim < 1)
      return;
   if(adx[0] <= 0.0)
      return;

   if(g_regime == REGIME_SIDEWAYS)
   {
      if(adx[0] >= InpRegimeADXTrend)
      {
         if(dip[0] > dim[0])
         {
            g_regime = REGIME_UP;
            PrintFormat("REGIME -> UP (ADX %.2f, +DI %.2f, -DI %.2f)",
                        adx[0], dip[0], dim[0]);
         }
         else if(dim[0] > dip[0])
         {
            g_regime = REGIME_DOWN;
            PrintFormat("REGIME -> DOWN (ADX %.2f, +DI %.2f, -DI %.2f)",
                        adx[0], dip[0], dim[0]);
         }
      }
   }
   else
   {
      if(adx[0] <= InpRegimeADXExit)
      {
         PrintFormat("REGIME -> SIDEWAYS (ADX %.2f <= %.2f)",
                     adx[0], InpRegimeADXExit);
         g_regime = REGIME_SIDEWAYS;
      }
      else if(g_regime == REGIME_UP && dim[0] > dip[0])
      {
         PrintFormat("REGIME UP -> DOWN (-DI %.2f > +DI %.2f)", dim[0], dip[0]);
         g_regime = REGIME_DOWN;
      }
      else if(g_regime == REGIME_DOWN && dip[0] > dim[0])
      {
         PrintFormat("REGIME DOWN -> UP (+DI %.2f > -DI %.2f)", dip[0], dim[0]);
         g_regime = REGIME_UP;
      }
   }
}

//+------------------------------------------------------------------+
//| Izin arah berdasarkan rezim. UP: SELL dilarang. DOWN: BUY dilarang.|
//+------------------------------------------------------------------+
bool RegimeAllowsBuy()
{
   return (!InpUseRegimeGate || g_regime != REGIME_DOWN);
}

bool RegimeAllowsSell()
{
   return (!InpUseRegimeGate || g_regime != REGIME_UP);
}

//+------------------------------------------------------------------+
//| News filter kalender ekonomi MT5.                                |
//| Waktu kalender dan query memakai waktu trade server.             |
//+------------------------------------------------------------------+
bool IsNewsBlocked()
{
   if(!UiNewsOn())
   {
      g_news_blocked    = false;
      g_news_event_time = 0;
      g_news_event_name = "";
      return false;
   }

   // API kalender MT5 tidak tersedia di Strategy Tester. Fail-open
   // supaya backtest tetap berjalan; hasil tester tidak mencakup news.
   if(MQLInfoInteger(MQL_TESTER))
   {
      if(!g_news_tester_warned)
      {
         Print("News filter diabaikan di Strategy Tester karena API "
               "kalender MT5 tidak tersedia. Live/demo tetap didukung.");
         g_news_tester_warned = true;
      }
      g_news_blocked = false;
      return false;
   }

   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();
   if(now < g_news_next_check)
      return g_news_blocked;

   // Refresh 30 detik cukup untuk jendela news berbasis menit.
   g_news_next_check = now + 30;
   g_news_blocked    = false;
   g_news_event_time = 0;
   g_news_event_name = "";

   datetime time_from = now - InpNewsMinutesAfter  * 60;
   datetime time_to   = now + InpNewsMinutesBefore * 60;
   MqlCalendarValue values[];

   ResetLastError();
   int count = CalendarValueHistory(values, time_from, time_to,
                                    "", InpNewsCurrency);
   if(count < 0)
   {
      int err = GetLastError();
      if(now - g_last_news_warning >= 300)
      {
         PrintFormat("News filter gagal membaca kalender (%s), error %d. "
                     "Fail-open: anchor baru tetap diizinkan.",
                     InpNewsCurrency, err);
         g_last_news_warning = now;
      }
      return false;
   }

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event))
         continue;
      if((int)event.importance < (int)InpNewsMinImportance)
         continue;

      datetime block_from = values[i].time -
                            InpNewsMinutesBefore * 60;
      datetime block_to   = values[i].time +
                            InpNewsMinutesAfter * 60;
      if(now < block_from || now > block_to)
         continue;

      g_news_blocked    = true;
      g_news_event_time = values[i].time;
      g_news_event_name = event.name;
      break;
   }

   return g_news_blocked;
}

//+------------------------------------------------------------------+
//| Normalisasi harga ke tick size                                   |
//+------------------------------------------------------------------+
double NormPrice(double price)
{
   return NormalizeDouble(MathRound(price / g_tick_size) * g_tick_size, g_digits);
}

// Normalisasi arah bawah untuk SL BUY agar tidak melewati batas broker
double NormPriceDown(double price)
{
   return NormalizeDouble(MathFloor(price / g_tick_size) * g_tick_size, g_digits);
}

// Normalisasi arah atas untuk SL SELL agar tidak melewati batas broker
double NormPriceUp(double price)
{
   return NormalizeDouble(MathCeil(price / g_tick_size) * g_tick_size, g_digits);
}

//+------------------------------------------------------------------+
//| Normalisasi lot ke volume step / min / max                       |
//+------------------------------------------------------------------+
double NormLot(double lot)
{
   lot = MathFloor(lot / g_lot_step + 0.5) * g_lot_step;
   lot = MathMax(g_lot_min, MathMin(g_lot_max, lot));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Lot untuk level grid ke-n (level dimulai dari 1 = anchor)        |
//| Level 1..60  : BaseLot                                           |
//| Level 61..90 : 2 x BaseLot, dst (+BaseLot tiap 30 level)         |
//+------------------------------------------------------------------+
double LotForLevelBase(int level, double base)
{
   if(level <= InpLevelsFlat)
      return NormLot(base);
   int step = (int)MathCeil((double)(level - InpLevelsFlat) / (double)InpLevelsPerStep);
   return NormLot(base * (1.0 + step));
}

// Bentuk aslinya, dipertahankan apa adanya untuk grid utama.
double LotForLevel(int level)
{
   return LotForLevelBase(level, InpBaseLot);
}

// Lot dasar basket recovery, ditetapkan saat pemicu dan disimpan di GV
// supaya tahan restart. 0 berarti belum ditetapkan.
double   g_recov_base[2]      = {0.0, 0.0};

// Dompet recovery: profit yang sudah direalisasi tapi BELUM dibelanjakan.
// Ada karena satu siklus recovery sering tidak cukup membeli posisi yang
// benar-benar perlu ditutup. Tanpa dompet, profitnya terpaksa dipakai ke
// posisi termurah yang justru memperburuk BE.
double   g_recov_wallet[2]    = {0.0, 0.0};

string GVRecovBaseName(long magic)   { return "MasTri_" + _Symbol + "_" + (string)magic + "_rbase";   }
string GVRecovWalletName(long magic) { return "MasTri_" + _Symbol + "_" + (string)magic + "_rwallet"; }

void SetRecovWallet(long recov_magic, double v)
{
   int idx = DirIndex(LosingDirForRecov(recov_magic));
   g_recov_wallet[idx] = v;
   string gv = GVRecovWalletName(recov_magic);
   if(v > 0.0) GlobalVariableSet(gv, v);
   else if(GlobalVariableCheck(gv)) GlobalVariableDel(gv);
}

double GetRecovWallet(long recov_magic)
{
   int idx = DirIndex(LosingDirForRecov(recov_magic));
   if(g_recov_wallet[idx] <= 0.0)
   {
      string gv = GVRecovWalletName(recov_magic);
      if(GlobalVariableCheck(gv))
         g_recov_wallet[idx] = GlobalVariableGet(gv);
   }
   return g_recov_wallet[idx];
}

double BaseLotFor(long magic)
{
   if(!IsRecoveryMagic(magic))
      return InpBaseLot;

   int idx = DirIndex(LosingDirForRecov(magic));
   if(g_recov_base[idx] <= 0.0)
   {
      string gv = GVRecovBaseName(magic);
      if(GlobalVariableCheck(gv))
         g_recov_base[idx] = GlobalVariableGet(gv);
   }
   return (g_recov_base[idx] > 0.0) ? g_recov_base[idx] : InpBaseLot;
}

//+------------------------------------------------------------------+
//| Kedalaman basket: seberapa jauh harga bergerak MELAWAN basket.    |
//| BUY  : BE - harga.   SELL : harga - BE.                          |
//| Nol berarti tidak sedang adverse (basket di sisi profit).         |
//|                                                                  |
//| Ini sinyal utama gate kedalaman. Dibanding filter displacement,   |
//| angka ini tidak punya lag dan tidak bisa dikaburkan oleh ATR yang |
//| ikut membesar saat pergerakan berkelanjutan.                      |
//+------------------------------------------------------------------+
double BasketDepth(ENUM_POSITION_TYPE dir, double be, double price)
{
   if(be <= 0.0 || price <= 0.0)
      return 0.0;
   double d = (dir == POSITION_TYPE_BUY) ? (be - price) : (price - be);
   return (d > 0.0) ? d : 0.0;
}

//+------------------------------------------------------------------+
//| LotForLevel() di atas TIDAK diubah. Gate kedalaman dipasang di    |
//| pembungkus ini supaya rumus ramp aslinya tetap bisa dibaca dan    |
//| dibandingkan apa adanya.                                         |
//|                                                                  |
//| freeze_ramp true -> level baru memakai base lot, ramp dimatikan.  |
//| Ladder TIDAK dihentikan: level baru tetap dipasang sehingga BE     |
//| tetap membaik. Yang dihentikan hanya pertumbuhan eksposurnya.      |
//+------------------------------------------------------------------+
double LotForLevelGated(int level, bool freeze_ramp, double base)
{
   if(freeze_ramp)
      return NormLot(base);
   return LotForLevelBase(level, base);
}

//+------------------------------------------------------------------+
//| Perbarui latch gate kedalaman untuk satu arah.                    |
//| Return: freeze_ramp aktif atau tidak.                             |
//+------------------------------------------------------------------+
bool UpdateDepthGates(ENUM_POSITION_TYPE dir, long magic,
                      double be, double price, int &level_stride)
{
   int    idx   = SlotOf(magic);
   double depth = BasketDepth(dir, be, price);
   if(depth > g_depth_peak[idx])
      g_depth_peak[idx] = depth;

   string side = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";

   if(InpUseDepthLotFreeze && !g_lot_frozen[idx] &&
      depth >= InpLotFreezeDepth)
   {
      g_lot_frozen[idx] = true;
      PrintFormat("GATE LOT %s magic %I64d: kedalaman %.2f >= %.2f USD. "
                  "Ramp lot DIBEKUKAN ke base %.2f untuk sisa siklus ini. "
                  "Ladder tetap jalan, BE tetap membaik.",
                  side, magic, depth, InpLotFreezeDepth, NormLot(InpBaseLot));
   }

   if(InpUseDepthStepWiden && !g_step_widened[idx] &&
      depth >= InpStepWidenDepth)
   {
      g_step_widened[idx] = true;
      PrintFormat("GATE STEP %s magic %I64d: kedalaman %.2f >= %.2f USD. "
                  "Jarak antar level dilebarkan %.2f -> %.2f USD.",
                  side, magic, depth, InpStepWidenDepth,
                  InpGridStep, InpStepWidenTo);
   }

   level_stride = 1;
   if(g_step_widened[idx] && InpGridStep > 0.0)
      level_stride = (int)MathMax(1.0,
                                 MathRound(InpStepWidenTo / InpGridStep));

   return g_lot_frozen[idx];
}

//+------------------------------------------------------------------+
//| Hitung jumlah posisi terbuka grid (filter magic + symbol)        |
//+------------------------------------------------------------------+
int CountPositions(long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(magic)) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Hitung jumlah pending order grid                                 |
//+------------------------------------------------------------------+
int CountPendings(long magic)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)     continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)       continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Klasifikasi kegagalan request broker.                             |
//|                                                                  |
//| Ini perlu karena respons yang tepat berbeda per jenis kegagalan.  |
//| v1.50 awal hanya bereaksi pada 10016 invalid stops, padahal log   |
//| demo XAUUSDm menunjukkan broker ini menolak modify dengan 10011   |
//| "common error", cancel dengan 10013 "invalid request", dan place  |
//| dengan 10006 "rejected" - tidak satu pun 10016. Akibatnya         |
//| back-off jarak stop tidak pernah jalan.                           |
//|                                                                  |
//|  FAIL_DISTANCE  : harga/jarak stop salah -> lebarkan back-off      |
//|  FAIL_TRANSIENT : gangguan sementara -> tunggu, JANGAN lebarkan    |
//|                   jarak, karena masalahnya bukan jarak             |
//|  FAIL_STALE     : objek sudah tidak ada -> bukan error, abaikan    |
//|  FAIL_BLOCKED   : izin / kondisi akun -> laporkan, berhenti coba   |
//|  FAIL_OTHER     : belum dikenali -> laporkan apa adanya            |
//+------------------------------------------------------------------+
enum ENUM_FAIL_CLASS
{
   FAIL_DISTANCE,
   FAIL_TRANSIENT,
   FAIL_STALE,
   FAIL_BLOCKED,
   FAIL_OTHER
};

ENUM_FAIL_CLASS ClassifyRetcode(uint ret)
{
   switch(ret)
   {
      // Jarak / harga stop
      case TRADE_RETCODE_INVALID_STOPS:      // 10016
      case TRADE_RETCODE_INVALID_PRICE:      // 10015
         return FAIL_DISTANCE;

      // Sementara: server sibuk, requote, harga bergerak, koneksi
      case TRADE_RETCODE_REQUOTE:            // 10004
      case TRADE_RETCODE_REJECT:             // 10006
      case TRADE_RETCODE_ERROR:              // 10011 "common error"
      case TRADE_RETCODE_TIMEOUT:            // 10012
      case TRADE_RETCODE_PRICE_CHANGED:      // 10020
      case TRADE_RETCODE_PRICE_OFF:          // 10021
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  // 10024
      case TRADE_RETCODE_CONNECTION:         // 10031
         return FAIL_TRANSIENT;

      // Objek sudah berubah / tidak ada lagi: bukan kesalahan EA
      case TRADE_RETCODE_INVALID:            // 10013
      case TRADE_RETCODE_NO_CHANGES:         // 10025
      case TRADE_RETCODE_ORDER_CHANGED:      // 10023
      case TRADE_RETCODE_INVALID_ORDER:      // 10035
      case TRADE_RETCODE_POSITION_CLOSED:    // 10036
      case TRADE_RETCODE_CLOSE_ORDER_EXIST:  // 10039
         return FAIL_STALE;

      // Kondisi akun / simbol: mencoba lagi tidak akan menolong
      case TRADE_RETCODE_TRADE_DISABLED:     // 10017
      case TRADE_RETCODE_MARKET_CLOSED:      // 10018
      case TRADE_RETCODE_NO_MONEY:           // 10019
      case TRADE_RETCODE_SERVER_DISABLES_AT: // 10026
      case TRADE_RETCODE_CLIENT_DISABLES_AT: // 10027
      case TRADE_RETCODE_LOCKED:             // 10028
      case TRADE_RETCODE_FROZEN:             // 10029
      case TRADE_RETCODE_INVALID_FILL:       // 10030
      case TRADE_RETCODE_LIMIT_ORDERS:       // 10033
      case TRADE_RETCODE_LIMIT_VOLUME:       // 10034
      case TRADE_RETCODE_LIMIT_POSITIONS:    // 10040
      case TRADE_RETCODE_LONG_ONLY:          // 10042
      case TRADE_RETCODE_SHORT_ONLY:         // 10043
      case TRADE_RETCODE_CLOSE_ONLY:         // 10044
      case TRADE_RETCODE_HEDGE_PROHIBITED:   // 10046
         return FAIL_BLOCKED;
   }
   return FAIL_OTHER;
}

string FailClassText(ENUM_FAIL_CLASS c)
{
   switch(c)
   {
      case FAIL_DISTANCE:  return "JARAK";
      case FAIL_TRANSIENT: return "SEMENTARA";
      case FAIL_STALE:     return "BASI";
      case FAIL_BLOCKED:   return "DIBLOKIR";
   }
   return "TIDAK DIKENALI";
}

//+------------------------------------------------------------------+
//| Cancel semua pending order grid.                                 |
//|                                                                  |
//| Order yang statusnya bukan PLACED dilewati: order yang sedang     |
//| dieksekusi atau sudah hilang akan menolak dengan 10013, dan itu   |
//| bukan kegagalan yang perlu dilaporkan. Yang dilaporkan hanya      |
//| penolakan yang benar-benar berarti.                              |
//| Return jumlah order yang gagal dibatalkan karena alasan nyata.    |
//+------------------------------------------------------------------+
int CancelAllPendings(long magic)
{
   int real_fail = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)   continue;

      // Sedang diproses broker: jangan diganggu, tick berikutnya
      // order ini sudah jadi posisi atau sudah hilang sendiri.
      ENUM_ORDER_STATE state =
         (ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE);
      if(state != ORDER_STATE_PLACED && state != ORDER_STATE_PARTIAL)
         continue;

      if(trade.OrderDelete(ticket))
         continue;

      uint ret = trade.ResultRetcode();
      if(ClassifyRetcode(ret) == FAIL_STALE)
         continue;                  // order memang sudah tidak ada

      real_fail++;
      if(InpDebugExit)
         PrintFormat("Cancel gagal: order %I64u ret %u %s (%s)",
                     ticket, ret, trade.ResultRetcodeDescription(),
                     FailClassText(ClassifyRetcode(ret)));
   }
   return real_fail;
}

//+------------------------------------------------------------------+
//| Tutup seluruh basket satu arah secara atomik.                     |
//|                                                                  |
//| URUTAN PENTING: pending dibatalkan LEBIH DULU, baru posisi        |
//| ditutup. Kalau dibalik, satu burst harga bisa mengisi limit di    |
//| belakang posisi yang sedang ditutup dan basket terbelah - inilah  |
//| exit parsial yang terjadi di v1.43.                               |
//|                                                                  |
//| Pending disapu sekali lagi di akhir untuk menangkap limit yang    |
//| lolos di celah antara dua loop.                                   |
//|                                                                  |
//| Deviation dilonggarkan ke InpCloseSlippagePts selama close, lalu  |
//| dikembalikan. DEFAULT_DEVIATION_PTS (30 = 0.030 USD) terlalu      |
//| rapat untuk gold saat spike, justru gagal saat paling dibutuhkan. |
//|                                                                  |
//| Return true hanya kalau basket benar-benar bersih. Caller wajib   |
//| mengulang tiap tick sampai true.                                  |
//+------------------------------------------------------------------+
bool CloseBasket(long magic)
{
   CancelAllPendings(magic);

   trade.SetDeviationInPoints(InpCloseSlippagePts);
   trade.SetExpertMagicNumber(magic);

   int  failed    = 0;
   uint worst_ret = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(magic)) continue;

      ResetLastError();
      if(trade.PositionClose(ticket))
         continue;

      uint ret = trade.ResultRetcode();
      ENUM_FAIL_CLASS cls = ClassifyRetcode(ret);

      // Posisi sudah tutup di sisi broker: bukan kegagalan.
      if(cls == FAIL_STALE)
         continue;

      failed++;
      worst_ret = ret;
      if(InpDebugExit)
         PrintFormat("CloseBasket: ticket %I64u gagal [%s], ret %u %s, err %d",
                     ticket, FailClassText(cls), ret,
                     trade.ResultRetcodeDescription(), GetLastError());
   }

   trade.SetDeviationInPoints(DEFAULT_DEVIATION_PTS);

   // Sapu ulang: limit bisa terisi di celah antara cancel dan close.
   CancelAllPendings(magic);

   int left_pos  = CountPositions(magic);
   int left_pend = CountPendings(magic);

   if(left_pos == 0 && left_pend == 0)
      return true;

   if(InpDebugExit)
      PrintFormat("CloseBasket magic %I64d belum bersih: %d posisi, "
                  "%d pending, %d close gagal. Diulang tick berikutnya.",
                  magic, left_pos, left_pend, failed);

   // Basket macet: kalau close terus gagal, EA akan mengulang tiap tick
   // tanpa batas. Itu harus terlihat di log, bukan diam-diam.
   if(failed > 0 && TimeCurrent() - g_close_err_log >= 30)
   {
      PrintFormat("CLOSE BASKET MACET: magic %I64d masih %d posisi, "
                  "%d close gagal, ret terakhir %u [%s]. Retry terus "
                  "tiap tick. Kalau ini berulang, cek izin akun/simbol.",
                  magic, left_pos, failed, worst_ret,
                  FailClassText(ClassifyRetcode(worst_ret)));
      g_close_err_log = TimeCurrent();
   }
   return false;
}

//+------------------------------------------------------------------+
//| Breakeven rata-rata tertimbang basket                            |
//+------------------------------------------------------------------+
double BasketBreakEven(long magic)
{
   double sum_lp = 0.0, sum_l = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(magic)) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      sum_lp += vol * PositionGetDouble(POSITION_PRICE_OPEN);
      sum_l  += vol;
   }
   if(sum_l <= 0.0) return 0.0;
   return sum_lp / sum_l;
}

//+------------------------------------------------------------------+
//| Level grid terdalam yang sudah terisi (jarak dari anchor)        |
//| = 1 + jumlah step antara anchor dan entry ter-adverse            |
//+------------------------------------------------------------------+
int DeepestFilledLevel(ENUM_POSITION_TYPE dir, long magic, double anchor)
{
   double worst = anchor;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(magic)) continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(dir == POSITION_TYPE_BUY)  worst = MathMin(worst, op);
      else                          worst = MathMax(worst, op);
   }
   double dist = MathAbs(anchor - worst);
   return 1 + (int)MathRound(dist / InpGridStep);
}

//+------------------------------------------------------------------+
//| Level ladder terjauh yang sudah punya pending order              |
//+------------------------------------------------------------------+
int FarthestPendingLevel(ENUM_POSITION_TYPE dir, long magic, double anchor)
{
   int farthest = 1; // anchor = level 1
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)   continue;
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      double dist  = MathAbs(anchor - price);
      int lvl = 1 + (int)MathRound(dist / InpGridStep);
      if(lvl > farthest) farthest = lvl;
   }
   return farthest;
}

//+------------------------------------------------------------------+
//| Buka anchor market order (awal siklus)                           |
//+------------------------------------------------------------------+
bool OpenAnchor(ENUM_POSITION_TYPE dir, long magic)
{
   // Guard terakhir di titik eksekusi. Semua caller seharusnya sudah memeriksa
   // izin, tetapi anchor tidak boleh lolos bila state berubah menjadi
   // BLOCKED/PROBE sebelum request market dikirim.
   if(!FastGateAllowsAnchor(dir, magic))
      return false;

   trade.SetExpertMagicNumber(magic);
   double lot = NormLot(BaseLotFor(magic));
   bool ok;
   double price;
   if(dir == POSITION_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ok = trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, InpComment);
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ok = trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, InpComment);
   }
   if(ok)
   {
      // Simpan anchor price untuk perhitungan level ladder
      GlobalVariableSet(GVAnchorName(magic), NormPrice(price));
   }
   else
      Print("Anchor gagal (", EnumToString(dir), "): ", trade.ResultRetcodeDescription());
   return ok;
}

//+------------------------------------------------------------------+
//| Pasang satu limit order pada level tertentu                      |
//+------------------------------------------------------------------+
//| Perhitungan harga, lot, dan level TIDAK diubah dari v1.43.        |
//| Yang ditambahkan hanya pelaporan: g_place_reject diset kalau broker|
//| yang menolak (bukan level yang memang sudah tidak valid), supaya   |
//| caller bisa berhenti mencoba di tick itu.                          |
bool PlaceLimitAtLevel(ENUM_POSITION_TYPE dir, long magic, double anchor,
                       int level, bool freeze_ramp)
{
   // Guard terakhir di titik request: tidak ada jalur lain yang boleh
   // menyelipkan pending arah adverse ketika gate sudah BLOCKED.
   if(FastGateBlocksPending(dir, magic) ||
      !FastGateProbeReady(dir, magic))
      return false;

   trade.SetExpertMagicNumber(magic);
   double lot = LotForLevelGated(level, freeze_ramp, BaseLotFor(magic));
   double dist = InpGridStep * (level - 1);
   double price, market;
   long   stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist = stops * g_point;
   bool   ok;

   // Acuan validitas memakai sisi spread yang BERLAWANAN dengan sisi
   // eksekusi order. Buy-limit dieksekusi di Ask, jadi diukur dari Bid;
   // sell-limit dieksekusi di Bid, jadi diukur dari Ask.
   //
   // v1.43 memakai sisi yang sama dengan eksekusi, sehingga level bisa
   // jatuh DI DALAM spread dan langsung ditolak broker. Log 6 Aug
   // 08:26:44: sell-limit level 2 di 4283.792 sementara Ask 4283.802 -
   // hanya 0.010 di bawah Ask, padahal spread saat itu 0.260. Dengan
   // InpGridStep 0.25, level 2 SELALU tertelan spread selebar itu.
   //
   // Harga level, lot, dan penomoran level tidak berubah. Yang berubah
   // hanya level yang tidak mungkin valid kini dilewati tanpa dikirim.
   if(dir == POSITION_TYPE_BUY)
   {
      price  = NormPrice(anchor - dist);
      market = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(price >= market - min_dist)
         return false; // level sudah tidak valid sebagai buy-limit
      ok = trade.BuyLimit(lot, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, InpComment);
   }
   else
   {
      price  = NormPrice(anchor + dist);
      market = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(price <= market + min_dist)
         return false; // level sudah tidak valid sebagai sell-limit
      ok = trade.SellLimit(lot, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, InpComment);
   }

   if(ok)
      return true;

   // Broker menolak. Ini berbeda dari "level tidak valid" di atas, dan
   // harus menghentikan refill di tick ini: tanpa itu loop refill
   // mencoba sampai InpBatchRefill*5 kali dan menghasilkan burst request
   // gagal pada setiap tick.
   uint ret = trade.ResultRetcode();
   ENUM_FAIL_CLASS cls = ClassifyRetcode(ret);
   g_place_reject = true;

   if(ret != g_place_last_ret || TimeCurrent() - g_place_err_log >= 60)
   {
      PrintFormat("Pasang limit gagal [%s]: %s level %d di %s "
                  "(market %s, lot %.2f) ret %u %s, err %d",
                  FailClassText(cls),
                  (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL",
                  level, DoubleToString(price, g_digits),
                  DoubleToString(market, g_digits), lot,
                  ret, trade.ResultRetcodeDescription(), GetLastError());
      g_place_err_log  = TimeCurrent();
      g_place_last_ret = ret;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Jaga ladder: pastikan >= InpPendingBatch limit di depan harga    |
//+------------------------------------------------------------------+
void MaintainLadder(ENUM_POSITION_TYPE dir, long magic, double anchor,
                    double be, double price)
{
   // Basket sedang ditutup: tidak boleh ada limit baru sama sekali.
   // Memasang limit di sini berarti membuka posisi baru di belakang
   // basket yang sedang dilikuidasi - inilah exit parsial v1.43.
   if(g_closing[SlotOf(magic)])
      return;

   // Saat floating protection aktif, ladder dibongkar: semua limit yang
   // belum terisi dibatalkan dan tidak ada level baru dipasang, supaya
   // floating loss tidak bertambah. Posisi terbuka tetap dibiarkan dan
   // trailing SL basket terus berjalan di ApplyBasketStop().
   if(g_floating_protection_block)
   {
      if(CountPendings(magic) > 0)
         CancelAllPendings(magic);
      return;
   }

   // Tombol EA di panel dalam keadaan JEDA. Tidak ada level baru, dan limit
   // yang belum terisi dibatalkan supaya harga yang terus berjalan tidak
   // mengisinya. Posisi yang sudah ada TIDAK ditutup: trailing dan exit
   // basketnya tetap jalan lewat ApplyBasketStop().
   if(!UiEaOn())
   {
      if(CountPendings(magic) > 0)
         CancelAllPendings(magic);
      return;
   }

   // ---------------- FAST ADVERSE-TREND GATE ----------------
   // Berlaku pada grid UTAMA yang sudah aktif dan recovery. Sinyal tidak
   // bergantung pada floating: BUY diblokir hanya selama tren turun sangat
   // kuat, SELL hanya selama tren naik sangat kuat. Tidak ada posisi yang
   // ditutup. Pending dibatalkan agar tidak terus terisi, lalu ladder masuk
   // PROBE satu order per cooldown ketika impuls sudah benar-benar mereda.
   if(FastGateBlocksPending(dir, magic))
   {
      int pend_now = CountPendings(magic);
      if(pend_now > 0)
         CancelAllPendings(magic);
      static datetime s_fast_gate_log[BASKET_SLOTS] = {0, 0, 0, 0};
      int slot = SlotOf(magic);
      if(TimeCurrent() - s_fast_gate_log[slot] >= 60)
      {
         PrintFormat("FAST GATE %s magic %I64d BLOCKED (%s): %d pending "
                     "dibatalkan, %d posisi tetap dipegang. TANPA CUT LOSS.",
                     BasketName(magic), magic,
                     g_fast_gate_reason[DirIndex(dir)], pend_now,
                     CountPositions(magic));
         s_fast_gate_log[slot] = TimeCurrent();
      }
      return;
   }

   // Fallback perilaku lama bila fast gate dimatikan dari input.
   if(!InpUseFastTrendGate && InpRecoveryTrendGate &&
      IsRecoveryMagic(magic) && !TrendAllows(dir))
   {
      if(CountPendings(magic) > 0)
         CancelAllPendings(magic);
      return;
   }

   if(!FastGatePrepareProbe(dir))
      return;

   int pending_target = FastGatePendingTarget(dir, magic);
   int pendings = CountPendings(magic);
   if(pending_target <= 0)
      return;

   // Invariant PROBE: maksimal satu pending per basket dan hanya satu
   // placement per arah/cooldown. Kalau cancel pada fase BLOCKED belum tuntas,
   // jangan biarkan 2-6 pending lama tetap hidup; sapu semua lalu tunggu tick
   // berikutnya. Kegagalan cancel akan dicoba ulang, tanpa memasang order baru.
   if(pendings > pending_target)
   {
      CancelAllPendings(magic);
      return;
   }
   if(pendings >= pending_target || !FastGateProbeReady(dir, magic))
      return;

   // Gate kedalaman. Pemetaan level -> harga TIDAK diubah: harga level n
   // tetap anchor +/- InpGridStep * (n-1). Pelebaran step diwujudkan dengan
   // MELANGKAHI nomor level (stride), bukan dengan mengubah InpGridStep.
   //
   // Ini penting: DeepestFilledLevel() dan FarthestPendingLevel() memetakan
   // harga kembali ke nomor level lewat pembagian dengan InpGridStep. Kalau
   // InpGridStep yang diubah di tengah siklus, pemetaan itu jadi salah dan
   // penomoran level - yang juga dipakai ramp lot - ikut rusak. Dengan
   // stride, semua harga tetap berada di grid 0.25 yang sama.
   int  stride     = 1;
   bool freeze_lot = UpdateDepthGates(dir, magic, be, price, stride);

   // Lanjutkan ladder mulai dari level setelah level pending terjauh
   int deepest_filled  = DeepestFilledLevel(dir, magic, anchor);
   int farthest_pend   = FarthestPendingLevel(dir, magic, anchor);
   int next_level      = MathMax(deepest_filled, farthest_pend) + stride;

   // FRONTIER PLACEMENT: level berikutnya tidak pernah di belakang harga.
   // Tanpa ini next_level selalu mulai dari level terdalam yang terisi;
   // setelah blokir lepas saat gerak tajam, limit ditempatkan di harga murah
   // yang langsung terisi - itulah yang menumpuk floating. Level pertama
   // yang harganya masih di depan harga pasar:
   //   SELL : anchor + step*(n-1) > price
   //   BUY  : anchor - step*(n-1) < price
   if(InpFrontierPlacement)
   {
      int ahead = (dir == POSITION_TYPE_BUY)
                  ? 2 + (int)MathFloor((anchor - price) / InpGridStep)
                  : 2 + (int)MathFloor((price - anchor) / InpGridStep);
      if(ahead > next_level)
      {
         int fslot = SlotOf(magic);
         static datetime s_frontier_log[BASKET_SLOTS] = {0, 0, 0, 0};
         if(ahead > MathMax(deepest_filled, farthest_pend) + 1 &&
            TimeCurrent() - s_frontier_log[fslot] >= 60)
         {
            PrintFormat("FRONTIER %s magic %I64d: harga %s sudah melewati level "
                        "%d-%d (terdalam %d, pending terjauh %d). Level terlewat "
                        "ditinggalkan, limit baru mulai level %d. TANPA CUT LOSS, "
                        "posisi terbuka tetap dipegang.",
                        BasketName(magic), magic,
                        DoubleToString(price, g_digits),
                        deepest_filled + 1, ahead - 1, deepest_filled,
                        farthest_pend, ahead);
            s_frontier_log[fslot] = TimeCurrent();
         }
         next_level = ahead;
      }
   }

   int refill_count = FastGateRefillCount(dir, magic);
   int needed = pending_target - pendings;
   refill_count = MathMin(refill_count, needed);
   if(refill_count <= 0) return;

   int placed = 0;
   int lvl = next_level;
   int guard = 0;
   g_place_reject = false;
   while(placed < refill_count && guard < refill_count * 5)
   {
      if(PlaceLimitAtLevel(dir, magic, anchor, lvl, freeze_lot))
         placed++;
      else if(g_place_reject)
         break;      // broker menolak: hentikan refill, coba tick berikutnya
      lvl += stride;
      guard++;
   }
   if(placed > 0)
      FastGateMarkProbePlacement(dir, magic);
}

//+------------------------------------------------------------------+
//| Jarak minimum SL yang efektif dari harga.                         |
//|                                                                  |
//| Pengganti BrokerMinStopDistance() v1.43, yang hanya membaca       |
//| SYMBOL_TRADE_STOPS_LEVEL dan FREEZE_LEVEL. Broker XAUUSDm         |
//| melaporkan 0 pada keduanya tapi tetap menegakkan minimum dinamis, |
//| sehingga SL arming 0.10-0.20 dari harga selalu ditolak dengan     |
//| retcode 10016 dan basket tidak pernah ambil profit.               |
//|                                                                  |
//| Karena itu jarak diambil dari yang TERBESAR di antara:            |
//|   - stops level dan freeze level (kalau broker memang melapor)    |
//|   - spread berjalan x InpNetSpreadMult (minimum dinamis biasanya   |
//|     berskala spread, dan spread melebar justru saat news)          |
//|   - InpNetMinDistance (lantai hasil kalibrasi)                     |
//|   - satu tick (SL tidak boleh sama dengan harga)                   |
//| ditambah g_stop_pad, back-off yang melebar sendiri kalau broker    |
//| masih menolak.                                                    |
//|                                                                  |
//| Dibaca tiap panggilan: stops level, freeze level, dan spread       |
//| semuanya bisa berubah di tengah sesi.                             |
//+------------------------------------------------------------------+
double EffectiveMinStopDistance()
{
   long   stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = (ask > 0.0 && bid > 0.0 && ask > bid) ? (ask - bid) : 0.0;

   double dist = (double)stops * g_point;
   dist = MathMax(dist, (double)freeze * g_point);
   dist = MathMax(dist, spread * InpNetSpreadMult);
   dist = MathMax(dist, InpNetMinDistance);
   dist = MathMax(dist, g_tick_size);

   return dist + g_stop_pad;
}

//+------------------------------------------------------------------+
//| Jarak minimum versi v1.43: HANYA yang dilaporkan broker.          |
//|                                                                  |
//| Dipakai khusus mode baseline (InpUseVirtualTrailing OFF) supaya    |
//| perbandingan backtest Task 8 mengukur satu perubahan saja, yaitu   |
//| eksekutor exit. Kalau baseline ikut memakai jarak minimum yang     |
//| baru, jarak trailing efektifnya berubah dari 0.20 ke 0.50 dan      |
//| angkanya jadi tidak bisa dibandingkan.                            |
//|                                                                  |
//| Di Strategy Tester angka ini biasanya 0 + tick, jadi mode baseline |
//| mereplikasi v1.43 apa adanya. Di akun live back-off tetap ikut     |
//| melebar, sehingga mode baseline tidak macet total seperti v1.43.   |
//+------------------------------------------------------------------+
double ReportedMinStopDistance()
{
   long   stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double dist   = MathMax((double)stops, (double)freeze) * g_point;
   return MathMax(dist, g_tick_size) + g_stop_pad;
}

//+------------------------------------------------------------------+
//| Jarak minimum yang dipakai jalur exit, sesuai mode aktif.          |
//+------------------------------------------------------------------+
double ExitMinStopDistance()
{
   return InpUseVirtualTrailing ? EffectiveMinStopDistance()
                                : ReportedMinStopDistance();
}

//+------------------------------------------------------------------+
//| Adaptive back-off: dipanggil HANYA saat broker menolak dengan     |
//| invalid stops. Melebar bertahap, ada batas atas, satu baris log   |
//| per pelebaran (bukan ratusan baris invalid stops seperti v1.43).  |
//+------------------------------------------------------------------+
void WidenStopPad(uint retcode)
{
   // Hanya kegagalan yang benar-benar soal jarak/harga yang melebarkan
   // jarak. Menyetel ulang jarak karena "common error" atau requote
   // justru salah sasaran: masalahnya bukan di jarak, dan melebarkan
   // jarak malah mengurangi profit yang terkunci tanpa alasan.
   if(ClassifyRetcode(retcode) != FAIL_DISTANCE)
      return;

   g_pad_widen_streak++;

   // Sudah melebar berkali-kali dan broker tetap menolak: berhenti
   // melebarkan. Terus melebarkan bukan cuma tidak menolong, tapi aktif
   // merusak - jarak yang makin lebar membuat clamp BE menahan jaring
   // selamanya, sehingga posisi malah tidak punya SL sama sekali.
   // Pad dibalikkan ke 0 dan jaring diistirahatkan.
   bool at_max = (g_stop_pad >= g_stop_pad_max - g_tick_size * 0.5);
   if(at_max || g_pad_widen_streak > PAD_WIDEN_STREAK_MAX)
   {
      g_giveup_count++;
      if(g_giveup_count <= GIVEUP_REPORT_MAX)
      {
         PrintFormat("BACK-OFF MENYERAH (ke-%d) setelah %d pelebaran, pad %s "
                     "USD, broker masih menolak: masalahnya BUKAN jarak. Pad "
                     "dikembalikan ke 0, jaring diistirahatkan %d detik. "
                     "Eksekusi exit tetap dipegang trailing virtual.",
                     g_giveup_count, g_pad_widen_streak,
                     DoubleToString(g_stop_pad, g_digits),
                     NET_GIVEUP_SEC);
         // Spesifikasi simbol persis pada saat penolakan, bukan saat
         // OnInit. Ini angka yang benar-benar berlaku waktu ditolak.
         Print("Spesifikasi simbol pada saat penolakan:");
         DumpSymbolSpec();
      }
      g_stop_pad          = 0.0;
      g_pad_widen_streak  = 0;
      g_net_giveup_until  = TimeCurrent() + NET_GIVEUP_SEC;
      return;
   }

   double old_pad = g_stop_pad;
   g_stop_pad = MathMin(g_stop_pad_max, g_stop_pad + g_stop_pad_step);
   PrintFormat("Invalid stops: back-off jarak stop dilebarkan %s -> %s USD "
               "(jarak minimum efektif kini %s USD, pelebaran ke-%d).",
               DoubleToString(old_pad, g_digits),
               DoubleToString(g_stop_pad, g_digits),
               DoubleToString(ExitMinStopDistance(), g_digits),
               g_pad_widen_streak);
}

//+------------------------------------------------------------------+
//| Back-off direset saat kedua basket flat: lebar yang terpaksa      |
//| dipakai saat satu sesi ramai tidak perlu diwarisi siklus berikut. |
//+------------------------------------------------------------------+
void MaybeResetStopPad()
{
   if(g_stop_pad <= 0.0)
      return;
   if(CountPositions(InpMagicBuy) > 0 || CountPositions(InpMagicSell) > 0)
      return;

   PrintFormat("Kedua basket flat: back-off jarak stop direset dari %s ke 0.",
               DoubleToString(g_stop_pad, g_digits));
   g_stop_pad          = 0.0;
   g_stop_pad_max_warn = false;
}

//+------------------------------------------------------------------+
//| SL terbaik yang SUDAH terpasang pada basket.                      |
//| BUY  : SL tertinggi, SELL : SL terendah.                          |
//| Nilai ini menjadi acuan "tidak pernah mundur" dan sekaligus       |
//| penanda bahwa trailing sudah aktif (tahan restart EA).            |
//+------------------------------------------------------------------+
double BasketBestSL(ENUM_POSITION_TYPE dir, long magic, bool &has_sl)
{
   double best = 0.0;
   has_sl = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(magic)) continue;

      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0) continue;

      if(!has_sl)
      {
         best   = sl;
         has_sl = true;
         continue;
      }
      best = (dir == POSITION_TYPE_BUY) ? MathMax(best, sl)
                                        : MathMin(best, sl);
   }
   return best;
}

//+------------------------------------------------------------------+
//| Berapa posisi basket yang sudah punya SL server?                  |
//| Dipakai untuk mendeteksi basket campur setelah restart.            |
//+------------------------------------------------------------------+
int CountPositionsWithSL(long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(magic)) continue;
      if(PositionGetDouble(POSITION_SL) > 0.0) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Simpan level trailing virtual + cerminkan ke global variable      |
//| terminal, mengikuti pola GVAnchorName(). Ini yang membuat level    |
//| virtual selamat dari restart EA di tengah siklus.                  |
//+------------------------------------------------------------------+
void SetVirtualStop(ENUM_POSITION_TYPE dir, long magic, double level)
{
   int    idx = SlotOf(magic);
   string gvv = GVVStopName(magic);

   g_vstop[idx] = level;
   if(level > 0.0)
      GlobalVariableSet(gvv, level);
   else if(GlobalVariableCheck(gvv))
      GlobalVariableDel(gvv);
}

//+------------------------------------------------------------------+
//| Bersihkan seluruh state siklus satu arah, termasuk GV vstop dan   |
//| GV anchor. Dipanggil saat basket benar-benar kosong supaya siklus |
//| berikutnya tidak pernah arming dari level basi.                   |
//+------------------------------------------------------------------+
void ClearCycleState(ENUM_POSITION_TYPE dir, long magic)
{
   int idx = SlotOf(magic);

   g_vstop[idx]            = 0.0;
   g_net_last[idx]         = 0.0;
   g_net_fail_val[idx]     = 0.0;
   g_net_cool_until[idx]   = 0;
   g_net_last_ret[idx]     = 0;
   g_adopt_logged[idx]     = false;
   g_trail_widen_warn[idx] = false;
   g_clamp_log[idx]        = 0;
   g_clamp_active[idx]     = false;

   // Gate kedalaman dilepas hanya di sini: latch-nya berlaku satu siklus.
   g_lot_frozen[idx]       = false;
   g_step_widened[idx]     = false;
   g_depth_peak[idx]       = 0.0;

   string gvv = GVVStopName(magic);
   if(GlobalVariableCheck(gvv)) GlobalVariableDel(gvv);
   string gva = GVAnchorName(magic);
   if(GlobalVariableCheck(gva)) GlobalVariableDel(gva);
}

//+------------------------------------------------------------------+
//| Ringkasan basket yang diadopsi setelah restart. Dicetak sekali    |
//| per siklus, bukan tiap tick.                                     |
//+------------------------------------------------------------------+
void AnnounceAdoption(ENUM_POSITION_TYPE dir, long magic,
                      double level, string source)
{
   int idx = SlotOf(magic);
   if(g_adopt_logged[idx])
      return;
   g_adopt_logged[idx] = true;

   int n_pos = CountPositions(magic);
   int n_sl  = CountPositionsWithSL(magic);

   PrintFormat("Basket %s magic %I64d DIADOPSI: %d posisi (%d ber-SL server), "
               "BE %s, level virtual %s dipulihkan dari %s. "
               "Trailing lanjut dari level ini, tanpa arming ulang.",
               (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL", magic,
               n_pos, n_sl,
               DoubleToString(BasketBreakEven(magic), g_digits),
               DoubleToString(level, g_digits), source);

   if(n_sl > 0 && n_sl < n_pos)
      PrintFormat("Basket %s campur: %d dari %d posisi belum ber-SL. "
                  "Sisanya disinkronkan ke jaring saat ini, bukan nilai basi.",
                  (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL",
                  n_pos - n_sl, n_pos);
}

//+------------------------------------------------------------------+
//| Rekonsiliasi state siklus. Dipanggil di OnInit dan di awal        |
//| ManageGrid.                                                      |
//|                                                                  |
//| Tiga kasus:                                                      |
//|  1. Basket kosong -> buang GV vstop + anchor dan reset memori.     |
//|  2. GV vstop ada   -> pulihkan level virtual apa adanya.           |
//|  3. GV vstop hilang tapi basket masih memegang SL server ->        |
//|     rekonstruksi level dari BasketBestSL() supaya trailing lanjut  |
//|     dari level yang sama, bukan arming ulang dari BE baru.         |
//+------------------------------------------------------------------+
void ReconcileBasket(ENUM_POSITION_TYPE dir, long magic)
{
   int    idx = SlotOf(magic);
   string gvv = GVVStopName(magic);

   if(CountPositions(magic) == 0)
   {
      if(g_vstop[idx] > 0.0 || GlobalVariableCheck(gvv))
         ClearCycleState(dir, magic);
      return;
   }

   if(g_vstop[idx] > 0.0)
      return;                         // state di memori sudah valid

   if(GlobalVariableCheck(gvv))
   {
      double saved = GlobalVariableGet(gvv);
      if(saved > 0.0)
      {
         g_vstop[idx] = saved;
         AnnounceAdoption(dir, magic, saved, "global variable");
         return;
      }
      GlobalVariableDel(gvv);
   }

   bool   has_sl = false;
   double best   = BasketBestSL(dir, magic, has_sl);
   if(has_sl && best > 0.0)
   {
      g_vstop[idx] = best;
      GlobalVariableSet(gvv, best);
      AnnounceAdoption(dir, magic, best, "SL server basket");
   }
   // Kalau dua-duanya tidak ada, basket memang belum armed. Biarkan
   // arming normal berjalan dari BE saat ini.
}

//+------------------------------------------------------------------+
//| Pelihara level trailing satu arah: arming lalu ratchet.           |
//|                                                                  |
//| Rumusnya dipakai APA ADANYA dari v1.43 (lihat RevEngExit.mqh):    |
//| arming di BE +/- InpProfitOffset ditambah buffer konfirmasi,       |
//| jarak InpTrailingDistance dari harga berjalan, maju hanya bila     |
//| lompatannya >= InpTrailingStep, tidak pernah mundur.               |
//|                                                                  |
//| Satu fungsi ini melayani dua mode:                                |
//|  - InpUseVirtualTrailing ON : jarak dipakai apa adanya, level ini  |
//|    yang dieksekusi CloseBasket().                                 |
//|  - OFF (baseline v1.43)     : jarak dan buffer dilebarkan ke batas |
//|    legal broker, karena di mode ini SL server yang jadi eksekutor  |
//|    dan SL pertama harus bisa terpasang.                           |
//|                                                                  |
//| Acuan "tidak mundur" adalah level virtual itu sendiri, bukan       |
//| lock_target. Penting: lock_target ikut bergerak saat level ladder  |
//| baru terisi (BE berubah), dan di versi lama itu membuat kandidat   |
//| ditolak sehingga SL membeku walau harga sudah jalan jauh.          |
//|                                                                  |
//| Return true kalau level sudah armed.                              |
//+------------------------------------------------------------------+
bool UpdateVirtualLevel(ENUM_POSITION_TYPE dir, long magic, double be,
                        double price, double eff_min)
{
   int idx  = SlotOf(magic);
   int sign = DirSign(dir);

   double trail_dist, arm_buffer;
   if(InpUseVirtualTrailing)
   {
      trail_dist = MathMax(InpTrailingDistance, g_tick_size);
      arm_buffer = MathMax(InpSLBuffer, g_tick_size);
   }
   else
   {
      trail_dist = MathMax(InpTrailingDistance, eff_min);
      arm_buffer = MathMax(InpSLBuffer, eff_min + g_tick_size);

      if(trail_dist > InpTrailingDistance + g_tick_size * 0.5 &&
         !g_trail_widen_warn[idx])
      {
         PrintFormat("TrailingDistance %.5f lebih rapat dari jarak legal %.5f. "
                     "Jarak trailing dilebarkan otomatis ke %.5f.",
                     InpTrailingDistance, eff_min, trail_dist);
         g_trail_widen_warn[idx] = true;
      }
   }

   double trail_step = MathMax(InpTrailingStep, g_tick_size);

   double lock = ExitLockTarget(sign, be, ProfitOffsetFor(magic));
   if(lock <= 0.0)
      return (g_vstop[idx] > 0.0);

   // Target dinormalisasi ke arah yang tidak mengurangi profit minimum.
   double lock_norm = (dir == POSITION_TYPE_BUY) ? NormPriceUp(lock)
                                                 : NormPriceDown(lock);

   //--- Belum armed: tunggu harga melewati target + buffer
   if(g_vstop[idx] <= 0.0)
   {
      if(!IsArmTriggered(sign, price, lock_norm, arm_buffer))
         return false;

      // NextVirtualStop sengaja tidak tahu lock_target. Penggabungan di
      // sini yang menjamin profit minimum InpProfitOffset ikut terkunci
      // pada level pertama.
      double raw   = NextVirtualStop(sign, price, trail_dist, trail_step,
                                     0.0, g_tick_size);
      double first = (dir == POSITION_TYPE_BUY) ? MathMax(lock_norm, raw)
                                                : MathMin(lock_norm, raw);
      SetVirtualStop(dir, magic, NormalizeDouble(first, g_digits));

      PrintFormat("EXIT ARMED %s magic %I64d: BE %s | target %s | harga %s "
                  "| level %s (jarak %.2f) | eksekutor %s",
                  (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL", magic,
                  DoubleToString(be, g_digits),
                  DoubleToString(lock_norm, g_digits),
                  DoubleToString(price, g_digits),
                  DoubleToString(g_vstop[idx], g_digits),
                  MathAbs(price - g_vstop[idx]),
                  InpUseVirtualTrailing ? "virtual" : "SL server");
      return true;
   }

   //--- Sudah armed: ratchet mengikuti harga
   double next = NormalizeDouble(
                    NextVirtualStop(sign, price, trail_dist, trail_step,
                                    g_vstop[idx], g_tick_size), g_digits);
   if(!RevExitSamePrice(next, g_vstop[idx], g_tick_size))
   {
      if(InpDebugExit)
         PrintFormat("VSTOP %s: %s -> %s (harga %s)",
                     (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL",
                     DoubleToString(g_vstop[idx], g_digits),
                     DoubleToString(next, g_digits),
                     DoubleToString(price, g_digits));
      SetVirtualStop(dir, magic, next);
   }
   return true;
}

//+------------------------------------------------------------------+
//| Jaring pengaman: SL server di belakang level virtual.             |
//|                                                                  |
//| Eksekutor exit adalah CloseBasket(). SL server hanya jaring kalau |
//| EA mati, terminal tertutup, atau koneksi hilang. Karena jaring    |
//| harus berada di jarak legal broker, ia selalu LEBIH LONGGAR dari  |
//| level virtual.                                                   |
//|                                                                  |
//| CLAMP BE: kalau jarak legal memaksa net melewati breakeven        |
//| basket, net TIDAK dipasang sama sekali. Tidak boleh ada SL yang   |
//| merugi - itu bertentangan dengan prinsip tanpa cut loss.          |
//|                                                                  |
//| Mode baseline (InpUseVirtualTrailing OFF) tidak memakai clamp BE: |
//| di mode itu SL server adalah eksekutor, jadi perilakunya dijaga   |
//| sama seperti v1.43 supaya pembanding backtest adil.               |
//|                                                                  |
//| Perbaikan penting dari v1.43: keputusan "lewati posisi ini"       |
//| sekarang ada DI DALAM loop dan memakai continue. Di v1.43 guard   |
//| anti-mundur memakai return di luar loop, sehingga satu posisi     |
//| yang SL-nya sudah lebih baik membatalkan sinkronisasi seluruh     |
//| basket - posisi ber-sl=0 tidak pernah ikut terpasang.             |
//+------------------------------------------------------------------+
void ApplyBasketStop(ENUM_POSITION_TYPE dir, long magic, double be,
                     double price, double eff_min)
{
   if(!InpUseSafetyNetSL)
      return;

   int idx  = SlotOf(magic);
   int sign = DirSign(dir);

   double vstop = g_vstop[idx];
   if(vstop <= 0.0)
      return;                         // belum armed: tidak ada yang dijaring

   // Sudah disimpulkan masalahnya bukan jarak: berhenti mengetuk broker
   // untuk sementara. Exit tetap jalan lewat trailing virtual.
   if(TimeCurrent() < g_net_giveup_until)
      return;

   double tol = g_tick_size * 0.5;

   //--- Kandidat legal saat ini
   double fresh;
   if(InpUseVirtualTrailing)
   {
      // Sudah dijamin memenuhi jarak minimum DAN tidak melewati BE.
      // 0 = jarak legal memaksa net merugi -> jangan pasang apa pun.
      fresh = NetStopCandidate(sign, price, vstop, be, eff_min, g_tick_size);
   }
   else
   {
      // Baseline v1.43: clamp hanya ke batas legal, tanpa clamp BE.
      double legal = (dir == POSITION_TYPE_BUY)
                     ? RevExitFloorToTick(price - eff_min, g_tick_size)
                     : RevExitCeilToTick(price + eff_min, g_tick_size);
      fresh = (dir == POSITION_TYPE_BUY) ? MathMin(vstop, legal)
                                         : MathMax(vstop, legal);
      if(fresh <= 0.0)
         fresh = 0.0;
   }

   if(fresh <= 0.0)
   {
      // Ini keadaan yang stabil, bukan kejadian. Dicetak saat MASUK
      // keadaan itu saja, bukan tiap menit selamanya seperti versi
      // sebelumnya yang membanjiri log 10 menit berturut-turut.
      if(!g_clamp_active[idx])
      {
         g_clamp_active[idx] = true;
         PrintFormat("Jaring pengaman %s DITAHAN: jarak legal %s USD dari "
                     "harga %s akan menempatkan SL melewati BE %s. "
                     "Tidak ada SL merugi. Exit dipegang virtual %s. "
                     "Pesan ini tidak diulang sampai keadaan berubah.",
                     (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL",
                     DoubleToString(eff_min, g_digits),
                     DoubleToString(price, g_digits),
                     DoubleToString(be, g_digits),
                     DoubleToString(vstop, g_digits));
         g_clamp_log[idx] = TimeCurrent();
      }
      return;
   }

   if(g_clamp_active[idx])
   {
      g_clamp_active[idx] = false;
      PrintFormat("Jaring pengaman %s LEPAS: kandidat %s kembali di sisi "
                  "aman BE %s.",
                  (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL",
                  DoubleToString(fresh, g_digits),
                  DoubleToString(be, g_digits));
   }

   fresh = NormalizeDouble(fresh, g_digits);

   //--- Ratchet: net tidak pernah mundur
   double net = fresh;
   if(g_net_last[idx] > 0.0)
      net = (dir == POSITION_TYPE_BUY) ? MathMax(g_net_last[idx], fresh)
                                       : MathMin(g_net_last[idx], fresh);
   g_net_last[idx] = net;

   // Cooldown kegagalan: setelah broker menolak, arah ini diam sejenak
   // supaya tidak ada burst request di tick-tick berikutnya. Ratchet di
   // atas tetap diperbarui, yang ditahan hanya pengirimannya.
   if(TimeCurrent() < g_net_cool_until[idx])
      return;

   // Kalau ratchet mendorong net ke zona terlarang (harga balik
   // mendekat), net basket tidak dikirim ulang: nilainya sudah terpasang
   // di server, jadi tidak ada yang perlu diubah dan tidak ada 10016.
   bool net_sendable = IsStopDistanceLegal(sign, price, net, eff_min,
                                           g_tick_size);

   int attempts = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(magic)) continue;

      double cur_sl = PositionGetDouble(POSITION_SL);
      double cur_tp = PositionGetDouble(POSITION_TP);
      double cur_op = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE cur_type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double want;

      if(cur_sl <= 0.0)
      {
         // Fill baru atau basket campur: SELALU disinkronkan tanpa
         // menunggu TrailingStep, tapi ke nilai legal SAAT INI, bukan
         // nilai basi. Nilai ini bisa lebih longgar dari net basket -
         // itu disengaja, jaring tidak seragam masih jauh lebih baik
         // daripada posisi tanpa SL sama sekali.
         want = fresh;
      }
      else
      {
         if(!net_sendable)
            continue;                  // SL lama sudah benar, biarkan

         double advance = (dir == POSITION_TYPE_BUY) ? (net - cur_sl)
                                                     : (cur_sl - net);
         if(advance <= tol)
            continue;                  // dedup: sama atau sudah lebih baik
         want = net;
      }

      // Nilai yang sudah pernah ditolak untuk arah ini tidak dikirim
      // ulang KE TICKET YANG SAMA. Kandidat BUY hanya bisa naik dan SELL
      // hanya bisa turun, tapi keduanya di-floor ke BE, jadi saat
      // back-off melebar kandidatnya sering tetap sama persis dengan yang
      // baru ditolak. Ticket lain tetap boleh dicoba dengan nilai itu:
      // penolakan bisa bersifat per-posisi, misalnya SL terlalu dekat ke
      // entry posisi itu sendiri.
      if(g_net_fail_val[idx] > 0.0 && ticket == g_net_fail_ticket[idx] &&
         RevExitSamePrice(want, g_net_fail_val[idx], g_tick_size))
         continue;

      if(attempts >= NET_ATTEMPTS_PER_TICK)
         break;
      attempts++;

      ResetLastError();
      if(trade.PositionModify(ticket, want, cur_tp))
      {
         // Jalur pulih: nilai ini terbukti diterima broker, jadi catatan
         // kegagalan dibuang dan hitungan pelebaran direset. Tanpa reset
         // ini, satu penolakan lama masih menghitung ke arah "menyerah"
         // walau jaring sudah bekerja normal.
         g_net_fail_val[idx]  = 0.0;
         g_net_last_ret[idx]  = 0;
         g_pad_widen_streak   = 0;
         g_stop_pad_max_warn  = false;
         continue;
      }

      uint ret = trade.ResultRetcode();
      int  err = GetLastError();
      ENUM_FAIL_CLASS cls = ClassifyRetcode(ret);

      // Posisi sudah tutup, atau tidak ada perubahan yang perlu dikirim:
      // bukan kegagalan, lanjut ke posisi berikutnya.
      if(cls == FAIL_STALE)
         continue;

      int cooldown = NET_FAIL_COOLDOWN_SEC;

      bool force_log = false;

      if(cls == FAIL_DISTANCE)
      {
         // Sepuluh kegagalan jarak pertama dilaporkan LENGKAP tanpa
         // throttle. Baris inilah yang menentukan apakah sebabnya sisi SL
         // salah, jarak ke entry, atau memang jarak ke harga - dan di
         // versi sebelumnya justru baris ini yang tertelan throttle 60
         // detik sehingga yang tersisa hanya baris ringkas dari CTrade.
         if(g_dist_fail_logged < DIST_FAIL_LOG_MAX)
         {
            g_dist_fail_logged++;
            force_log = true;
         }
         g_net_fail_val[idx]    = want;
         g_net_fail_ticket[idx] = ticket;
         WidenStopPad(ret);
      }
      else if(cls == FAIL_BLOCKED)
      {
         // Mencoba lagi tidak akan menolong: diam jauh lebih lama.
         cooldown = NET_BLOCKED_COOLDOWN_SEC;
      }
      // FAIL_TRANSIENT dan FAIL_OTHER: nilainya belum tentu salah, jadi
      // TIDAK di-blacklist dan jarak TIDAK dilebarkan. Cukup tunggu lalu
      // coba lagi apa adanya.

      g_net_cool_until[idx] = TimeCurrent() + cooldown;

      // Retcode jenis baru dilaporkan segera; pengulangan jenis yang sama
      // baru dilaporkan lagi setelah 60 detik.
      if(force_log || ret != g_net_last_ret[idx] ||
         TimeCurrent() - g_trail_err_log[idx] >= 60)
      {
         // Baris ini sengaja dibuat BERDIRI SENDIRI: memuat semua yang
         // dibutuhkan untuk diagnosis, supaya satu baris yang dikutip
         // dari log sudah cukup tanpa perlu blok OnInit.
         //
         // Yang dicek dari baris ini:
         //  - sisi SL vs tipe posisi. SL di atas harga untuk BUY, atau di
         //    bawah harga untuk SELL, ditolak berapa pun jaraknya.
         //  - jarak SL ke ENTRY posisi. Sebagian broker menuntut minimum
         //    dari entry, bukan hanya dari harga berjalan.
         //  - jarak SL ke harga, lawan stops/freeze/spread yang benar-
         //    benar dilaporkan broker saat itu.
         long   s_lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
         long   f_lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
         double s_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double s_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         bool   wrong_side =
            ((cur_type == POSITION_TYPE_BUY  && want > price) ||
             (cur_type == POSITION_TYPE_SELL && want < price));

         PrintFormat("Jaring gagal [%s] ret %u %s err %d | ticket %I64u %s "
                     "entry %s | SL %s -> %s | SL %s harga%s | "
                     "jarak ke harga %s, ke entry %s | eff_min %s (pad %s) | "
                     "bid %s ask %s spread %s | stops %d freeze %d | "
                     "digits %d tick %s",
                     FailClassText(cls), ret,
                     trade.ResultRetcodeDescription(), err,
                     ticket, EnumToString(cur_type),
                     DoubleToString(cur_op, g_digits),
                     DoubleToString(cur_sl, g_digits),
                     DoubleToString(want, g_digits),
                     (want > price) ? "DI ATAS" : "DI BAWAH",
                     wrong_side ? " <<< SISI SALAH!" : "",
                     DoubleToString(MathAbs(want - price), g_digits),
                     DoubleToString(MathAbs(want - cur_op), g_digits),
                     DoubleToString(eff_min, g_digits),
                     DoubleToString(g_stop_pad, g_digits),
                     DoubleToString(s_bid, g_digits),
                     DoubleToString(s_ask, g_digits),
                     DoubleToString(s_ask - s_bid, g_digits),
                     (int)s_lvl, (int)f_lvl,
                     g_digits, DoubleToString(g_tick_size, 8));

         g_trail_err_log[idx] = TimeCurrent();
         g_net_last_ret[idx]  = ret;
      }

      // Tidak return: ticket LAIN masih boleh dicoba dalam tick ini,
      // dibatasi NET_ATTEMPTS_PER_TICK. Versi sebelumnya langsung return,
      // sehingga satu ticket yang selalu ditolak bisa membuat seluruh
      // basket tidak pernah dapat SL. Batas percobaan yang menahan burst,
      // bukan return.
   }
}

//+------------------------------------------------------------------+
//| ====================== HEDGE LOCK (v1.52) ======================  |
//|                                                                  |
//| Peran: menghentikan pertumbuhan floating pada basket yang sudah   |
//| terlalu besar relatif equity. BUKAN pemulihan - hedge matched      |
//| membekukan kerugian, tidak menghapusnya. Yang melunasi kerugian    |
//| beku itu penghasilan normal grid.                                 |
//|                                                                  |
//| Aturan keras:                                                     |
//|  1. Hedge TIDAK punya ladder. Satu sisi, volume matched, selesai.  |
//|  2. Magic sendiri (InpMagicHedge). Kalau masuk magic grid,         |
//|     BasketBreakEven ikut menghitungnya dan seluruh exit rusak.     |
//|  3. Volume di-top-up tiap tick selama basket tumbuh. Tanpa itu     |
//|     kuncinya bocor dan floating tetap membesar.                    |
//|  4. Ladder basket TIDAK dihentikan. Membekukannya membekukan BE,   |
//|     dan itu yang membuat basket tidak bisa exit.                   |
//+------------------------------------------------------------------+

// Arah hedge selalu berlawanan arah basket. Tipe posisi itulah yang
// membedakan hedge milik basket BUY dari milik basket SELL, jadi satu
// magic cukup untuk keduanya.
ENUM_POSITION_TYPE HedgeTypeFor(ENUM_POSITION_TYPE basket_dir)
{
   return (basket_dir == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL
                                            : POSITION_TYPE_BUY;
}

//+------------------------------------------------------------------+
//| Uang per 1 lot per 1.00 USD pergerakan harga, dalam mata uang     |
//| akun. Inilah yang membuat ambang ruin tidak perlu dikalibrasi:     |
//| XAUUSDm akun USD menghasilkan 100, XAUUSDc akun cent juga 100      |
//| tapi dalam sen, dan equity-nya juga dalam sen.                     |
//+------------------------------------------------------------------+
double MoneyPerUsdPerLot()
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tv > 0.0 && g_tick_size > 0.0)
      return tv / g_tick_size;
   return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
}

//+------------------------------------------------------------------+
//| Sisa ruang gerak harga sebelum equity habis, dalam USD.           |
//+------------------------------------------------------------------+
double RuinDistance(double exposure_lots)
{
   if(exposure_lots <= 0.0) return DBL_MAX;
   double per = MoneyPerUsdPerLot();
   if(per <= 0.0) return DBL_MAX;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) return 0.0;
   return eq / (exposure_lots * per);
}

//+------------------------------------------------------------------+
//| Eksposur NET seluruh magic EA pada simbol ini, dalam lot.          |
//| Positif = net long. Inilah yang benar-benar menentukan apakah      |
//| equity bisa bergerak.                                            |
//|                                                                  |
//| Perlu dibedakan dari volume basket, karena saat hedge terpasang    |
//| volume basket terus tumbuh tapi eksposur net tetap nol. Tanpa      |
//| pembedaan ini panel akan menampilkan "ruin 24" padahal posisinya   |
//| netral dan equity tidak bergerak sama sekali.                     |
//+------------------------------------------------------------------+
double NetExposureLots()
{
   double net = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!IsManagedMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      net += ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)
              == POSITION_TYPE_BUY) ? v : -v;
   }
   return net;
}

//+------------------------------------------------------------------+
//| Volume dan floating basket grid.                                  |
//+------------------------------------------------------------------+
double BasketVolume(long magic)
{
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsBasketPosition(magic)) continue;
      v += PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}

double BasketFloating(long magic)
{
   double s = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsBasketPosition(magic)) continue;
      s += PositionGetDouble(POSITION_PROFIT) +
           PositionGetDouble(POSITION_SWAP);
   }
   return s;
}

//+------------------------------------------------------------------+
//| Volume dan floating kaki hedge untuk satu arah basket.            |
//| Difilter magic hedge + tipe posisi, bukan lewat IsBasketPosition. |
//+------------------------------------------------------------------+
double HedgeVolume(ENUM_POSITION_TYPE hedge_type)
{
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicHedge) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != hedge_type)
         continue;
      v += PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}

double HedgeFloating(ENUM_POSITION_TYPE hedge_type)
{
   double s = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicHedge) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != hedge_type)
         continue;
      s += PositionGetDouble(POSITION_PROFIT) +
           PositionGetDouble(POSITION_SWAP);
   }
   return s;
}

//+------------------------------------------------------------------+
//| P/L terealisasi seluruh magic EA sejak waktu tertentu.             |
//| Inilah penghasilan yang melunasi kerugian beku.                    |
//+------------------------------------------------------------------+
double RealizedSince(datetime from)
{
   if(from <= 0) return 0.0;
   if(!HistorySelect(from, TimeCurrent() + 60)) return 0.0;

   double sum = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if(!IsManagedMagic(HistoryDealGetInteger(d, DEAL_MAGIC))) continue;
      ENUM_DEAL_ENTRY e =
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY) continue;
      sum += HistoryDealGetDouble(d, DEAL_PROFIT);
      sum += HistoryDealGetDouble(d, DEAL_SWAP);
      sum += HistoryDealGetDouble(d, DEAL_COMMISSION);
   }
   return sum;
}

//+------------------------------------------------------------------+
//| Tutup seluruh kaki hedge untuk satu arah basket.                  |
//+------------------------------------------------------------------+
bool CloseHedge(ENUM_POSITION_TYPE basket_dir)
{
   ENUM_POSITION_TYPE ht = HedgeTypeFor(basket_dir);
   trade.SetDeviationInPoints(InpCloseSlippagePts);
   trade.SetExpertMagicNumber(InpMagicHedge);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicHedge) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ht) continue;

      if(trade.PositionClose(t)) continue;
      uint ret = trade.ResultRetcode();
      if(ClassifyRetcode(ret) == FAIL_STALE) continue;
      if(InpDebugExit)
         PrintFormat("CloseHedge: ticket %I64u gagal, ret %u %s",
                     t, ret, trade.ResultRetcodeDescription());
   }
   trade.SetDeviationInPoints(DEFAULT_DEVIATION_PTS);
   return (HedgeVolume(ht) <= 0.0);
}

//+------------------------------------------------------------------+
//| Simpan / pulihkan state hedge.                                    |
//+------------------------------------------------------------------+
void SetHedgeState(ENUM_POSITION_TYPE dir, long magic,
                   bool on, double frozen, datetime since)
{
   int idx = DirIndex(dir);
   g_hedge_on[idx]     = on;
   g_hedge_frozen[idx] = frozen;
   g_hedge_since[idx]  = since;

   string gf = GVHedgeFrozName(magic), gs = GVHedgeSinceName(magic);
   if(on)
   {
      GlobalVariableSet(gf, frozen);
      GlobalVariableSet(gs, (double)since);
   }
   else
   {
      if(GlobalVariableCheck(gf)) GlobalVariableDel(gf);
      if(GlobalVariableCheck(gs)) GlobalVariableDel(gs);
   }
}

//+------------------------------------------------------------------+
//| Kelola hedge lock untuk satu arah basket.                         |
//| Return true kalau basket sedang terkunci hedge.                    |
//+------------------------------------------------------------------+
bool ManageHedge(ENUM_POSITION_TYPE dir, long magic, double price)
{
   if(!InpUseHedgeLock)
      return false;

   int    idx = DirIndex(dir);
   ENUM_POSITION_TYPE ht = HedgeTypeFor(dir);
   double bvol = BasketVolume(magic);
   double hvol = HedgeVolume(ht);
   string side = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";

   //--- basket habis: bersihkan sisa hedge kalau masih ada
   if(bvol <= 0.0)
   {
      if(hvol > 0.0)
      {
         PrintFormat("HEDGE %s: basket sudah kosong, sisa hedge %.2f lot "
                     "ditutup.", side, hvol);
         CloseHedge(dir);
      }
      if(g_hedge_on[idx])
         SetHedgeState(dir, magic, false, 0.0, 0);
      return false;
   }

   //--- rekonstruksi state setelah restart
   if(!g_hedge_on[idx] && hvol > 0.0)
   {
      double froz = 0.0;
      datetime since = 0;
      string gf = GVHedgeFrozName(magic), gs = GVHedgeSinceName(magic);
      if(GlobalVariableCheck(gf))  froz  = GlobalVariableGet(gf);
      if(GlobalVariableCheck(gs))  since = (datetime)GlobalVariableGet(gs);
      if(froz == 0.0)  froz  = BasketFloating(magic) + HedgeFloating(ht);
      if(since == 0)   since = TimeCurrent();
      SetHedgeState(dir, magic, true, froz, since);
      PrintFormat("HEDGE %s DIADOPSI setelah restart: hedge %.2f lot, "
                  "kerugian beku %.2f, sejak %s",
                  side, hvol, froz,
                  TimeToString(since, TIME_DATE | TIME_MINUTES));
   }

   double ruin = RuinDistance(bvol);

   //--- belum terkunci: cek pemicu
   if(!g_hedge_on[idx])
   {
      if(ruin > InpHedgeRuinDistance)
         return false;

      double froz = BasketFloating(magic);
      double want = NormLot(bvol * InpHedgeRatio);
      if(want < g_lot_min)
         return false;

      trade.SetDeviationInPoints(InpCloseSlippagePts);
      trade.SetExpertMagicNumber(InpMagicHedge);
      bool ok = (ht == POSITION_TYPE_BUY)
                ? trade.Buy(want, _Symbol, 0.0, 0.0, 0.0, "HEDGE")
                : trade.Sell(want, _Symbol, 0.0, 0.0, 0.0, "HEDGE");
      trade.SetDeviationInPoints(DEFAULT_DEVIATION_PTS);

      if(!ok)
      {
         PrintFormat("HEDGE %s GAGAL dibuka %.2f lot: ret %u %s",
                     side, want, trade.ResultRetcode(),
                     trade.ResultRetcodeDescription());
         return false;
      }

      SetHedgeState(dir, magic, true, froz, TimeCurrent());
      PrintFormat("HEDGE %s DIBUKA: basket %.2f lot, ruin %.1f <= %.1f USD. "
                  "Hedge %s %.2f lot di %s. Kerugian DIBEKUKAN di %.2f. "
                  "Pelunasan menunggu profit >= %.2f.",
                  side, bvol, ruin, InpHedgeRuinDistance,
                  (ht == POSITION_TYPE_BUY) ? "BUY" : "SELL", want,
                  DoubleToString(price, g_digits), froz,
                  MathAbs(froz) * InpHedgeUnwindMult);
      return true;
   }

   //--- sudah terkunci: TOP-UP supaya kunci tidak bocor
   double target = NormLot(bvol * InpHedgeRatio);
   double gap    = target - hvol;
   if(gap >= g_lot_min - 1e-8)
   {
      double add = NormLot(gap);
      trade.SetDeviationInPoints(InpCloseSlippagePts);
      trade.SetExpertMagicNumber(InpMagicHedge);
      bool ok = (ht == POSITION_TYPE_BUY)
                ? trade.Buy(add, _Symbol, 0.0, 0.0, 0.0, "HEDGE")
                : trade.Sell(add, _Symbol, 0.0, 0.0, 0.0, "HEDGE");
      trade.SetDeviationInPoints(DEFAULT_DEVIATION_PTS);
      if(ok && InpDebugExit)
         PrintFormat("HEDGE %s top-up +%.2f -> %.2f lot (basket %.2f)",
                     side, add, hvol + add, bvol);
      else if(!ok)
         PrintFormat("HEDGE %s top-up %.2f GAGAL: ret %u %s", side, add,
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   //--- cek unwind, di-throttle supaya HistorySelect tidak tiap tick
   if(TimeCurrent() - g_hedge_check[idx] >= HEDGE_CHECK_SEC)
   {
      g_hedge_check[idx] = TimeCurrent();
      double need = MathAbs(g_hedge_frozen[idx]) * InpHedgeUnwindMult;
      double got  = RealizedSince(g_hedge_since[idx]);
      if(got >= need && need > 0.0)
      {
         PrintFormat("HEDGE %s UNWIND: profit terealisasi %.2f >= %.2f "
                     "(kerugian beku %.2f x %.2f). Menutup basket dan hedge.",
                     side, got, need, g_hedge_frozen[idx],
                     InpHedgeUnwindMult);
         CloseHedge(dir);
         g_closing[idx] = true;
         return true;
      }
      if(InpDebugExit)
         PrintFormat("HEDGE %s terkunci: basket %.2f lot, hedge %.2f lot, "
                     "beku %.2f, profit sejak %.2f / %.2f",
                     side, bvol, HedgeVolume(ht), g_hedge_frozen[idx],
                     got, need);
   }
   return true;
}

//+------------------------------------------------------------------+
//| ==================== RECOVERY GRID (v1.53) ====================   |
//|                                                                  |
//| Basket pemulihan yang menghasilkan profit NYATA lalu membelanjakan |
//| profit itu untuk menutup posisi terburuk basket yang minus.         |
//|                                                                  |
//| Bedanya dengan hedge lock: hedge hanya membekukan kerugian pada     |
//| besaran saat ia dibuka, karena setiap keuntungan kaki hedge persis  |
//| dihapus kerugian tambahan basket. Recovery tidak saling menghapus - |
//| ia dibuka, dibiarkan mencapai target, lalu DITUTUP. Profitnya masuk |
//| balance sebagai uang baru, dan uang itu dipakai membuang posisi     |
//| minus. Volume basket turun, floating turun, BE membaik.            |
//|                                                                  |
//| Mekanikanya sama dengan grid biasa EA ini - anchor, ladder, BE      |
//| basket, trailing exit - jadi dijalankan lewat ManageGrid() yang    |
//| sama, hanya dengan magic dan target profit sendiri.                |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Belanjakan profit recovery untuk menutup posisi TERBURUK basket    |
//| yang minus.                                                       |
//|                                                                  |
//| "Terburuk" = P/L paling negatif. Untuk basket SELL itu entry       |
//| terendah, untuk BUY entry tertinggi. Menutupnya menggeser BE ke    |
//| arah yang menguntungkan, sehingga target exit basket mendekat.     |
//|                                                                  |
//| Hanya menutup selama masih tertutup budget: satu posisi yang       |
//| ruginya melebihi budget dilewati, bukan dipaksa.                   |
//+------------------------------------------------------------------+
//| PENTING - kenapa hanya posisi di SISI TERTENTU yang boleh ditutup:  |
//|                                                                  |
//| Menutup posisi menggeser BE basket. Untuk basket SELL, membuang     |
//| entry DI BAWAH BE menaikkan BE, dan BE yang lebih tinggi berarti    |
//| target exit (BE - offset) lebih tinggi sehingga harga perlu turun   |
//| lebih sedikit. Untuk BUY berlaku kebalikannya.                     |
//|                                                                  |
//| Dan itu tepat posisi dengan P/L paling negatif. Jadi menutup yang  |
//| paling rugi memperbaiki DUA hal sekaligus: floating turun paling    |
//| banyak, dan exit mendekat.                                        |
//|                                                                  |
//| Versi pertama fungsi ini memilih "paling rugi yang masih tertutup   |
//| budget". Simulasi menunjukkan itu salah: budget per siklus $82.72   |
//| sementara posisi terburuk ruginya $114, jadi ia selalu jatuh ke     |
//| posisi TERMURAH - yang ada di sisi salah BE. Hasilnya floating       |
//| memang turun, tapi jarak exit MEMBURUK dari 39.49 ke 43.04 USD.     |
//|                                                                  |
//| Karena itu sekarang ada dompet: profit dikumpulkan sampai cukup     |
//| membeli posisi yang benar, bukan dibelanjakan ke yang salah.        |
//+------------------------------------------------------------------+
double SpendRecoveryProfit(long target_magic, double budget)
{
   if(budget <= 0.0) return 0.0;

   ENUM_POSITION_TYPE tdir = DirForMagic(target_magic);
   double spent = 0.0;
   int    closed = 0;
   double be_before  = BasketBreakEven(target_magic);
   double vol_before = BasketVolume(target_magic);
   double flt_before = BasketFloating(target_magic);
   int    n_before   = CountPositions(target_magic);

   trade.SetDeviationInPoints(InpCloseSlippagePts);
   trade.SetExpertMagicNumber(target_magic);

   double cheapest_needed = 0.0;

   for(int guard = 0; guard < 500; guard++)
   {
      double be = BasketBreakEven(target_magic);
      if(be <= 0.0) break;

      ulong  pick_ticket = 0;
      double pick_pl     = 0.0;
      double min_needed  = 0.0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(!IsBasketPosition(target_magic)) continue;

         double op = PositionGetDouble(POSITION_PRICE_OPEN);
         double pl = PositionGetDouble(POSITION_PROFIT) +
                     PositionGetDouble(POSITION_SWAP);
         if(pl >= 0.0) continue;

         // Hanya sisi yang memperbaiki BE.
         bool improves = (tdir == POSITION_TYPE_SELL) ? (op < be) : (op > be);
         if(!improves) continue;

         // Catat biaya termurah di sisi yang benar, untuk pelaporan.
         if(min_needed == 0.0 || -pl < min_needed) min_needed = -pl;

         if(-pl > budget - spent + 1e-8) continue;   // belum terjangkau

         // Yang paling rugi: penurunan floating terbesar sekaligus
         // perbaikan BE terbesar.
         if(pick_ticket == 0 || pl < pick_pl)
         {
            pick_ticket = t;
            pick_pl     = pl;
         }
      }

      if(pick_ticket == 0)
      {
         cheapest_needed = min_needed;
         break;
      }

      if(!trade.PositionClose(pick_ticket))
      {
         uint ret = trade.ResultRetcode();
         if(ClassifyRetcode(ret) == FAIL_STALE) continue;
         PrintFormat("RECOVERY belanja gagal: ticket %I64u ret %u %s",
                     pick_ticket, ret, trade.ResultRetcodeDescription());
         break;
      }
      spent += -pick_pl;
      closed++;
   }

   trade.SetDeviationInPoints(DEFAULT_DEVIATION_PTS);

   if(closed > 0)
   {
      double be_after = BasketBreakEven(target_magic);
      double off      = ProfitOffsetFor(target_magic);
      double px       = (tdir == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double need_bef = (tdir == POSITION_TYPE_BUY)
                        ? (be_before + off - px) : (px - (be_before - off));
      double need_aft = (be_after <= 0.0) ? 0.0
                        : ((tdir == POSITION_TYPE_BUY)
                           ? (be_after + off - px) : (px - (be_after - off)));
      PrintFormat("RECOVERY BELANJA %s: %d dari %d posisi ditutup, terpakai "
                  "%.2f dari %.2f. Volume %.2f -> %.2f. Floating %.2f -> "
                  "%.2f. BE %s -> %s. Jarak exit %.2f -> %.2f USD.",
                  BasketName(target_magic), closed, n_before, spent, budget,
                  vol_before, BasketVolume(target_magic),
                  flt_before, BasketFloating(target_magic),
                  DoubleToString(be_before, g_digits),
                  DoubleToString(be_after, g_digits),
                  need_bef, need_aft);
   }
   else if(cheapest_needed > 0.0)
      PrintFormat("RECOVERY %s: dompet %.2f belum cukup. Posisi termurah di "
                  "sisi yang memperbaiki BE butuh %.2f. Profit DIKUMPULKAN, "
                  "tidak dibelanjakan ke posisi yang salah.",
                  BasketName(target_magic), budget, cheapest_needed);
   else
      PrintFormat("RECOVERY %s: tidak ada posisi di sisi yang memperbaiki BE. "
                  "Dompet %.2f disimpan.",
                  BasketName(target_magic), budget);

   return spent;
}

//+------------------------------------------------------------------+
//| Apakah recovery boleh MEMBUKA siklus baru untuk basket yang rugi?  |
//|                                                                  |
//| Arahnya tidak diramal: kalau basket SELL yang rugi berarti harga    |
//| sedang naik, jadi recovery-nya BUY. Diturunkan dari fakta.          |
//|                                                                  |
//| Basket recovery yang SUDAH jalan tetap dikelola sampai exit walau   |
//| ambangnya sudah tidak terpenuhi - fungsi ini hanya mengatur siklus  |
//| BARU, sama seperti allow_new_cycle pada grid utama.                 |
//+------------------------------------------------------------------+
bool RecoveryAllowed(ENUM_POSITION_TYPE losing_dir)
{
   if(!UiRecovOn()) return false;

   long lmagic = (losing_dir == POSITION_TYPE_BUY) ? InpMagicBuy
                                                   : InpMagicSell;
   long rmagic = RecovMagicFor(losing_dir);
   int  idx    = DirIndex(losing_dir);

   double lvol = BasketVolume(lmagic);
   if(lvol <= 0.0)
   {
      // Basket yang dilayani sudah habis: episode recovery selesai.
      if(g_recov_base[idx] > 0.0)
      {
         PrintFormat("RECOVERY untuk %s SELESAI: basket yang dilayani sudah "
                     "kosong. Sisa dompet %.2f tetap di balance.",
                     BasketName(lmagic), GetRecovWallet(rmagic));
         g_recov_base[idx] = 0.0;
         string gv = GVRecovBaseName(rmagic);
         if(GlobalVariableCheck(gv)) GlobalVariableDel(gv);
         SetRecovWallet(rmagic, 0.0);
      }
      return false;
   }

   double lflt = BasketFloating(lmagic);
   if(lflt > -InpRecoveryTrigger)
      return false;

   // Trigger floating saja tidak cukup. Recovery baru wajib lolos safety
   // direction gate: RECOV-SELL tidak boleh lahir saat tren naik sangat kuat,
   // dan RECOV-BUY tidak boleh lahir saat tren turun sangat kuat. Saat PROBE,
   // anchor baru juga ditahan; hanya ladder basket lama yang boleh mencoba
   // pulih satu order per cooldown.
   ENUM_POSITION_TYPE rdir = DirForMagic(rmagic);
   if(!FastGateAllowsAnchor(rdir, rmagic))
      return false;

   // Tetapkan lot dasar sekali per episode, lalu simpan ke GV.
   if(g_recov_base[idx] <= 0.0)
   {
      // Lot dasar recovery = InpBaseLot x rasio, BUKAN volume basket x rasio.
      //
      // Koreksi cacat yang menghabiskan tiga akun pada 12 Agustus 2026.
      // Bentuk lamanya `lvol * InpRecoveryLotRatio` membuat lot dasar
      // mengikuti besarnya basket yang diselamatkan: basket 5,48 lot
      // menghasilkan lot dasar 1,37 - seratus tiga puluh tujuh kali lot
      // dasar grid biasa - lalu ramp level 21+ menggandakannya jadi 2,74.
      //
      // Terukur di tiga laporan, polanya identik:
      //   MC-v1.53   (real cent) : 22.020 pos lot kecil = +11.635,80
      //                               21 pos lot besar  = -21.808,20
      //   MC-v1.53-A (demo USD)  :  8.157 pos lot kecil = +11.777,70
      //                               24 pos lot besar  = -31.737,33
      //   MC-v1.54   (demo USD)  :  8.370 pos lot kecil = +11.834,01
      //                               27 pos lot besar  = -25.022,95
      //
      // Grid lot kecil UNTUNG di ketiganya. Antara 21 sampai 27 posisi
      // recovery raksasa menghapus dua sampai tiga kali lipat dari itu dan
      // menghabiskan akun. Ketiganya mencatat lot maksimum 2,74.
      //
      // Sekarang recovery membuka grid dengan lot dasar yang sama seperti
      // grid biasa dan meramp memakai aturan yang sama. Floating dikurangi
      // sedikit demi sedikit lewat banyak siklus kecil.
      double b = NormLot(InpBaseLot * UiRatio());
      if(b < g_lot_min) b = g_lot_min;
      g_recov_base[idx] = b;
      GlobalVariableSet(GVRecovBaseName(rmagic), b);

      double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                      SymbolInfoDouble(_Symbol, SYMBOL_BID);
      PrintFormat("RECOVERY DIPICU untuk %s: floating %.2f <= -%.2f, "
                  "basket %.2f lot. Recovery %s lot dasar %.2f, "
                  "target profit %.2f USD.",
                  BasketName(lmagic), lflt, InpRecoveryTrigger, lvol,
                  BasketName(rmagic), b, InpRecoveryTarget);
      PrintFormat("  perkiraan per siklus: bruto %.2f, biaya spread %.2f "
                  "(spread %.3f), bersih %.2f. Untuk menutup %.2f perlu "
                  "sekitar %d siklus.",
                  InpRecoveryTarget * b * MoneyPerUsdPerLot(),
                  spread * b * MoneyPerUsdPerLot(), spread,
                  (InpRecoveryTarget - spread) * b * MoneyPerUsdPerLot(),
                  -lflt,
                  (int)MathCeil(-lflt /
                     MathMax(1.0, (InpRecoveryTarget - spread) * b *
                                  MoneyPerUsdPerLot())));
   }
   return true;
}

//+------------------------------------------------------------------+
//| Anchor siklus: dari global variable, atau direkonstruksi dari      |
//| entry terbaik kalau GV hilang (restart tanpa GV).                  |
//+------------------------------------------------------------------+
double ReadAnchor(ENUM_POSITION_TYPE dir, long magic)
{
   string gv = GVAnchorName(magic);
   if(GlobalVariableCheck(gv))
   {
      double saved = GlobalVariableGet(gv);
      if(saved > 0.0)
         return saved;
   }

   double anchor = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(magic)) continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(anchor == 0.0)                       anchor = op;
      else if(dir == POSITION_TYPE_BUY)       anchor = MathMax(anchor, op);
      else                                    anchor = MathMin(anchor, op);
   }
   if(anchor > 0.0)
      GlobalVariableSet(gv, anchor);
   return anchor;
}

//+------------------------------------------------------------------+
//| Eksekusi exit: tutup basket, bersihkan state kalau sudah bersih.  |
//+------------------------------------------------------------------+
void RunClose(ENUM_POSITION_TYPE dir, long magic)
{
   int idx = SlotOf(magic);

   // Hedge ditutup BERSAMA basket. Kalau hanya basket yang ditutup, kaki
   // hedge tertinggal tanpa penyeimbang dan berubah jadi posisi arah -
   // itu bukan lagi hedge, itu taruhan.
   bool hedge_clean = true;
   if(InpUseHedgeLock && !IsRecoveryMagic(magic) &&
      HedgeVolume(HedgeTypeFor(dir)) > 0.0)
      hedge_clean = CloseHedge(dir);

   // Untuk basket recovery, floating tepat sebelum ditutup adalah profit
   // yang akan direalisasi. Diambil di sini karena setelah CloseBasket()
   // posisinya sudah tidak ada untuk dihitung.
   double recov_profit = 0.0;
   long   spend_target = 0;
   if(IsRecoveryMagic(magic))
   {
      recov_profit = BasketFloating(magic);
      spend_target = (LosingDirForRecov(magic) == POSITION_TYPE_BUY)
                     ? InpMagicBuy : InpMagicSell;
   }

   if(!CloseBasket(magic) || !hedge_clean)
      return;                    // belum bersih: diulang tick berikutnya

   if(!IsRecoveryMagic(magic) && g_hedge_on[DirIndex(dir)])
      SetHedgeState(dir, magic, false, 0.0, 0);

   // Inilah langkah yang membuat floating benar-benar berkurang: profit
   // recovery langsung dibelanjakan menutup posisi terburuk basket minus.
   if(spend_target != 0)
   {
      // Profit masuk dompet dulu, lalu dompet dibelanjakan. Sisa yang
      // belum terpakai tetap di dompet untuk siklus berikutnya.
      double wallet = GetRecovWallet(magic) + recov_profit;
      PrintFormat("RECOVERY %s tutup, hasil %.2f. Dompet jadi %.2f.",
                  BasketName(magic), recov_profit, wallet);
      if(wallet > 0.0)
      {
         double used = SpendRecoveryProfit(spend_target, wallet);
         wallet -= used;
      }
      SetRecovWallet(magic, MathMax(0.0, wallet));
   }

   PrintFormat("BASKET %s magic %I64d TERTUTUP BERSIH: 0 posisi, 0 pending. "
               "Siklus baru boleh dimulai.",
               (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL", magic);
   g_closing[idx] = false;
   ClearCycleState(dir, magic);
}

//+------------------------------------------------------------------+
//| State machine utama per arah grid                                |
//|                                                                  |
//| URUTAN v1.50, dibalik dari v1.43:                                 |
//|   1. rekonsiliasi state (tahan restart)                           |
//|   2. mode closing: ulangi CloseBasket sampai basket bersih         |
//|   3. STATE IDLE: bersihkan pending sisa, buka anchor baru          |
//|   4. baca anchor                                                  |
//|   5. hitung BE basket                                             |
//|   6. evaluasi exit: arming, ratchet, trigger close                 |
//|   7. MaintainLadder                                                |
//|   8. jaring pengaman SL                                            |
//|                                                                  |
//| Exit dievaluasi SEBELUM ladder. Di v1.43 ladder jalan lebih dulu,  |
//| jadi pada tick yang sama dengan keputusan exit EA masih memasang   |
//| limit baru di belakang basket yang akan ditutup.                   |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| EXIT PER-POSISI UNTUK BASKET RECOVERY                             |
//|                                                                  |
//| Berjalan BERDAMPINGAN dengan exit basket (BE +/- InpRecoveryTarget),|
//| mana yang lebih dulu tercapai. Hanya untuk magic recovery; grid     |
//| utama tidak tersentuh sama sekali.                                 |
//|                                                                  |
//| Kenapa ini ada, dari ReportHistory-v1.53.xlsx (akun 416192829):     |
//|                                                                  |
//|   13 Agt 14:57:44  recovery BUY menyala, 19 posisi 0.05 lot terisi  |
//|                    dalam 5 menit, entry 4386.644 .. 4382.087        |
//|   13 Agt 15:04:46  basket SELL yang dilayani TUTUP SENDIRI +18.41   |
//|   14 Agt 01:59     harga 4320.078, recovery floating -6.106,        |
//|                    dompet terisi NOL kali dalam 11 jam              |
//|                                                                  |
//| Penyebabnya: dompet hanya terisi kalau basket recovery tutup UTUH   |
//| di BE + target. BE-nya 4384.340 jadi target 4385.340, sementara     |
//| harga tertinggi setelah ladder lengkap cuma 4382.198 - kurang       |
//| 3.14 USD. Tidak pernah tercapai, jadi tidak ada satu pun cicilan.   |
//|                                                                  |
//| Dengan exit per-posisi, posisi terdalam (entry 4382.087) tutup di   |
//| 4383.087 - kurang 0.89 USD saja, tiga setengah kali lebih dekat.    |
//| Dan tiap posisi yang lepas langsung mengisi dompet, jadi cicilan    |
//| ke basket minus mulai bekerja jauh lebih awal dan lebih sering.     |
//|                                                                  |
//| CATATAN SATUAN: target diukur dari harga ENTRY ke harga TUTUP, dan  |
//| entry BUY terjadi di Ask sementara tutupnya di Bid. Jadi 0.50 itu   |
//| profit BERSIH setelah spread; harga perlu bergerak 0.50 + spread    |
//| dari entry agar tercapai.                                          |
//|                                                                  |
//| Efek samping yang harus disadari: ini menutup posisi TERBAIK lebih  |
//| dulu, jadi BE sisa basket recovery memburuk tiap kali satu lepas.   |
//| Itu sebabnya exit basket dipertahankan - ia menyapu sisanya dengan  |
//| efek subsidi, di mana posisi dalam yang untung menutupi posisi atas. |
//+------------------------------------------------------------------+
void CloseRecoveryWinners(long rmagic)
{
   if(InpRecoveryPosTarget <= 0.0) return;
   if(!IsRecoveryMagic(rmagic))    return;
   // Basket sedang dilikuidasi utuh: jangan ikut campur.
   if(g_closing[SlotOf(rmagic)])   return;
   if(CountPositions(rmagic) == 0)  return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return;

   // Tidak ada pemeriksaan freeze level di sini. Sempat saya pasang, lalu
   // saya cabut: freeze level mengatur jarak ke harga AKTIVASI pending
   // order dan ke SL/TP, bukan penutupan posisi di harga pasar. Kalau
   // dipakai membandingkan harga sekarang ke harga ENTRY, syaratnya bisa
   // selalu benar dan exit per-posisi tidak pernah jalan sama sekali -
   // gagal senyap. Penolakan broker sudah ditangani di bawah lewat
   // ClassifyRetcode, jadi tidak perlu menebak di depan.
   double gained = 0;
   int    closed = 0;
   trade.SetDeviationInPoints(InpCloseSlippagePts);
   trade.SetExpertMagicNumber(rmagic);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsBasketPosition(rmagic)) continue;
      ENUM_POSITION_TYPE ptype =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double now = (ptype == POSITION_TYPE_BUY) ? bid : ask;
      double gain = (ptype == POSITION_TYPE_BUY) ? (now - op) : (op - now);
      if(gain < InpRecoveryPosTarget) continue;

      double pl = PositionGetDouble(POSITION_PROFIT) +
                  PositionGetDouble(POSITION_SWAP);
      ResetLastError();
      if(!trade.PositionClose(ticket))
      {
         uint ret = trade.ResultRetcode();
         if(ClassifyRetcode(ret) == FAIL_STALE)
            continue;             // sudah tutup di sisi broker
         if(InpDebugExit)
            PrintFormat("Exit per-posisi gagal: ticket %I64u ret %u %s",
                        ticket, ret, trade.ResultRetcodeDescription());
         continue;
      }
      gained += pl;
      closed++;
   }
   trade.SetDeviationInPoints(DEFAULT_DEVIATION_PTS);
   if(closed == 0) return;

   PrintFormat("EXIT PER-POSISI %s: %d posisi tutup (target %.2f USD/pos), "
               "hasil %.2f. Sisa %d posisi.",
               BasketName(rmagic), closed, InpRecoveryPosTarget,
               gained, CountPositions(rmagic));

   // Hasilnya langsung masuk dompet lalu dibelanjakan menutup posisi
   // TERBURUK basket yang minus - inilah cicilan yang di laporan lalu
   // tidak pernah terjadi karena basket recovery tak pernah tutup utuh.
   if(gained <= 0.0) return;
   long spend_target = (LosingDirForRecov(rmagic) == POSITION_TYPE_BUY)
                       ? InpMagicBuy : InpMagicSell;
   double wallet = GetRecovWallet(rmagic) + gained;
   if(CountPositions(spend_target) > 0)
   {
      double used = SpendRecoveryProfit(spend_target, wallet);
      wallet -= used;
   }
   SetRecovWallet(rmagic, MathMax(0.0, wallet));
}

void ManageGrid(ENUM_POSITION_TYPE dir, long magic, bool allow_new_cycle)
{
   int idx = SlotOf(magic);

   //--- 1. Rekonsiliasi: pulihkan level virtual atau bersihkan state
   ReconcileBasket(dir, magic);

   //--- 2. Sedang menutup basket: tidak ada hal lain yang boleh jalan.
   //       Tidak ada limit baru, tidak ada anchor baru, retry tiap tick.
   if(g_closing[idx])
   {
      RunClose(dir, magic);
      return;
   }

   int nPos = CountPositions(magic);

   //--- 3. STATE IDLE: tidak ada posisi -> mulai siklus baru
   if(nPos == 0)
   {
      // Basket baru saja tertutup (atau start awal):
      // bersihkan semua pending sisa siklus lama
      if(CountPendings(magic) > 0)
      {
         CancelAllPendings(magic);
         return; // tunggu tick berikutnya agar order benar-benar bersih
      }

      // Filter arah/news/spread hanya menahan anchor baru. Basket yang
      // sudah aktif tetap dikelola pada STATE CYCLE_ACTIVE di bawah.
      if(!allow_new_cycle)
         return;

      if(!OpenAnchor(dir, magic))
         return;

      // Pending awal SENGAJA ditunda ke tick berikutnya. Event deal anchor
      // baru diproses lewat OnTradeTransaction setelah handler tick selesai;
      // kalau enam pending dipasang di sini, anchor yang menjadi fill ke-8
      // belum sempat memicu burst gate. Pada tick berikutnya state ACTIVE
      // menjalankan UpdateFastTrendGate lebih dulu, lalu MaintainLadder:
      // BLOCKED = tidak ada pending, PROBE = satu, NORMAL = batch biasa.
      // Anchor tetap terbuka dan dikelola; tidak ada cut loss.
      return;
   }

   //--- STATE CYCLE_ACTIVE

   //--- 4. Anchor
   double anchor = ReadAnchor(dir, magic);
   if(anchor <= 0.0)
      return;

   //--- 5. Breakeven basket
   double be = BasketBreakEven(magic);
   if(be <= 0.0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   // Harga acuan exit = harga tutup basket.
   double price   = (dir == POSITION_TYPE_BUY) ? bid : ask;
   double eff_min = ExitMinStopDistance();

   //--- 5b. Hedge lock. Dijalankan SEBELUM evaluasi exit supaya top-up
   //         tidak tertinggal satu tick di belakang pertumbuhan ladder.
   bool hedged = ManageHedge(dir, magic, price);
   if(g_closing[idx])            // unwind memicu penutupan
   {
      RunClose(dir, magic);
      return;
   }

   //--- 6. Exit: arming + ratchet, lalu trigger close kalau level kena
   bool armed = UpdateVirtualLevel(dir, magic, be, price, eff_min);

   if(InpUseVirtualTrailing && armed &&
      IsVirtualStopHit(DirSign(dir), price, g_vstop[idx]))
   {
      // v1.53c: VERIFIKASI ULANG SEBELUM MENEMBAK.
      //
      // IsVirtualStopHit() di atas hanya menjawab "apakah harga sudah
      // melewati level". Itu tidak sama dengan "apakah basket ini benar
      // benar untung sekarang". Dua hal bisa memisahkan keduanya:
      //
      //   1. Harga melompat melewati level dalam satu tick. Level tidak
      //      pernah tersentuh, yang tersentuh adalah harga di baliknya.
      //   2. BE bergeser sesudah level dikunci, karena ladder masih
      //      mengisi. Level lama jadi tidak lagi mewakili profit.
      //
      // Sesudah titik ini tidak ada jalan mundur: begitu g_closing aktif,
      // CloseBasket() harus diselesaikan sampai bersih, dan itu makan
      // 9 sampai 36 detik untuk 55-61 posisi. Membatalkan di tengah jalan
      // berarti exit parsial - bug v1.43 yang sudah dibayar mahal. Jadi
      // satu-satunya tempat yang benar untuk berkata "jangan" adalah di
      // sini, sebelum request pertama dikirim.
      //
      // Kalau ditahan, basket dibiarkan jalan: pending tetap dijaga,
      // ratchet tetap memperbaiki level, dan exit dicoba lagi tick
      // berikutnya. Tidak ada cut loss, tidak ada state yang berubah.
      //
      // Ratchet menjamin ini tidak macet. BUY: level hanya naik mengikuti
      // harga (price - TrailingDistance), jadi harga yang terus naik
      // akhirnya mengangkat level sampai selisihnya dari BE melewati
      // ambang. SELL berlaku sebaliknya.
      //
      // Ambangnya = target basket itu sendiri + cadangan drift per posisi.
      // Basis pakai ProfitOffsetFor() supaya recovery ditagih target
      // recovery-nya (InpRecoveryTarget), bukan target grid.
      double edge = (price - be) * DirSign(dir);
      double need = ProfitOffsetFor(magic) + InpExitEdgePerPos * nPos;

      if(edge < need - g_tick_size * 0.5)
      {
         if(TimeCurrent() - g_exit_block_log[idx] >= 30)
         {
            PrintFormat("EXIT DITAHAN %s magic %I64d: level %s kena, tapi "
                        "harga %s cuma %.3f dari BE %s (butuh %.3f = target "
                        "%.2f + %d posisi x %.3f). %.2f lot, penutupan butuh "
                        "waktu dan harga masih bisa lari. Basket jalan terus.",
                        (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL", magic,
                        DoubleToString(g_vstop[idx], g_digits),
                        DoubleToString(price, g_digits),
                        edge, DoubleToString(be, g_digits), need,
                        ProfitOffsetFor(magic), nPos, InpExitEdgePerPos,
                        BasketVolume(magic));
            g_exit_block_log[idx] = TimeCurrent();
         }
      }
      else
      {
         PrintFormat("EXIT TRIGGER %s magic %I64d: harga %s menyentuh level %s "
                     "| BE %s | margin %.3f (butuh %.3f) | %d posisi, "
                     "%d pending. Menutup basket.",
                     (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL", magic,
                     DoubleToString(price, g_digits),
                     DoubleToString(g_vstop[idx], g_digits),
                     DoubleToString(be, g_digits),
                     edge, need, nPos, CountPendings(magic));
         g_closing[idx] = true;
         RunClose(dir, magic);
         return;   // tidak ada ladder / jaring pada tick keputusan exit
      }
   }

   //--- 7. Jaga ladder limit order di sisi adverse.
   //       BE dan harga diteruskan supaya gate kedalaman bisa dievaluasi.
   MaintainLadder(dir, magic, anchor, be, price);

   //--- 8. Jaring pengaman SL server.
   //       Dilewati saat terkunci hedge: SL yang tersentuh akan menutup
   //       sebagian basket dan meninggalkan hedge kelebihan volume, yang
   //       mengubah posisi netral jadi posisi arah. Dan saat terkunci,
   //       delta sudah nol sehingga EA mati pun posisinya aman.
   if(!hedged)
      ApplyBasketStop(dir, magic, be, price, eff_min);
}
//+------------------------------------------------------------------+
