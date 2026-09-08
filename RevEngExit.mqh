//+------------------------------------------------------------------+
//|                                                   RevEngExit.mqh |
//|  Matematika exit basket EA_RevEng - FUNGSI MURNI.                |
//|                                                                  |
//|  Aturan file ini (supaya bisa diuji tanpa terminal/broker):       |
//|   1. TIDAK ADA pemanggilan API terminal: SymbolInfo*, Position*,  |
//|      Order*, Time*, Print*, GlobalVariable*.                      |
//|   2. TIDAK ADA state global. Hasil hanya bergantung pada argumen. |
//|   3. Semua parameter eksplisit, termasuk tick_size. Pembulatan    |
//|      ke grid tick dilakukan di dalam, bukan diserahkan ke caller. |
//|   4. Arah dikodekan sebagai int: > 0 = BUY, < 0 = SELL. Ini       |
//|      sengaja bukan ENUM_POSITION_TYPE supaya test harness tidak   |
//|      perlu konteks posisi.                                        |
//|                                                                  |
//|  Rumus trailing dipertahankan apa adanya dari v1.43:              |
//|    - arming di BE +/- ProfitOffset ditambah buffer konfirmasi     |
//|    - jarak trailing InpTrailingDistance dari harga berjalan       |
//|    - maju hanya bila lompatannya >= InpTrailingStep               |
//|    - tidak pernah mundur                                          |
//+------------------------------------------------------------------+
#ifndef REVENG_EXIT_MQH
#define REVENG_EXIT_MQH

#define REVEXIT_DIR_BUY    1
#define REVEXIT_DIR_SELL  -1

// Epsilon absolut untuk perbandingan "tepat di batas". Jauh di bawah
// tick terkecil instrumen yang dipakai (gold 3 digit = 0.001) sehingga
// tidak pernah menutupi perbedaan satu tick yang nyata.
#define REVEXIT_EPS       1e-8

//+------------------------------------------------------------------+
//| dir > 0 berarti BUY. Dipakai internal supaya intensinya jelas.    |
//+------------------------------------------------------------------+
bool RevExitIsBuy(const int dir)
{
   return (dir > 0);
}

//+------------------------------------------------------------------+
//| Toleransi perbandingan harga = setengah tick.                     |
//| Setengah tick tidak mungkin menutupi selisih 1 tick yang nyata,   |
//| tapi cukup untuk menyerap galat pembagian/perkalian double.       |
//+------------------------------------------------------------------+
double RevExitTol(const double tick)
{
   return (tick > 0.0) ? (tick * 0.5) : REVEXIT_EPS;
}

//+------------------------------------------------------------------+
//| Pembulatan ke bawah / ke atas pada grid tick.                     |
//|                                                                  |
//| price/tick untuk gold bernilai jutaan (4163.198 / 0.001), jadi    |
//| MathFloor mentah bisa jatuh satu tick terlalu rendah hanya karena |
//| representasi biner. Karena itu hasil bagi dicek dulu: kalau sudah |
//| praktis tepat di tick, kembalikan tick itu, jangan digeser.       |
//| Toleransi 1e-6 dinyatakan dalam satuan tick, sementara selisih    |
//| satu tick nyata bernilai 1.0 dalam satuan yang sama.              |
//+------------------------------------------------------------------+
double RevExitFloorToTick(const double price, const double tick)
{
   if(tick <= 0.0)
      return price;
   double q = price / tick;
   double r = MathRound(q);
   if(MathAbs(q - r) < 1e-6)
      return r * tick;
   return MathFloor(q) * tick;
}

double RevExitCeilToTick(const double price, const double tick)
{
   if(tick <= 0.0)
      return price;
   double q = price / tick;
   double r = MathRound(q);
   if(MathAbs(q - r) < 1e-6)
      return r * tick;
   return MathCeil(q) * tick;
}

//+------------------------------------------------------------------+
//| Dua harga dianggap sama bila selisihnya di bawah setengah tick.   |
//+------------------------------------------------------------------+
bool RevExitSamePrice(const double a, const double b, const double tick)
{
   return (MathAbs(a - b) <= RevExitTol(tick));
}

//+------------------------------------------------------------------+
//| ExitLockTarget                                                   |
//| Harga target profit basket: BE + offset (BUY) / BE - offset (SELL)|
//| Mengembalikan 0 bila BE belum valid (basket kosong).              |
//+------------------------------------------------------------------+
double ExitLockTarget(const int dir, const double be, const double offset)
{
   if(be <= 0.0)
      return 0.0;
   return RevExitIsBuy(dir) ? (be + offset) : (be - offset);
}

//+------------------------------------------------------------------+
//| IsArmTriggered                                                   |
//| Apakah harga sudah melewati target + buffer konfirmasi?           |
//| BUY  : price >= lock_target + arm_buffer                          |
//| SELL : price <= lock_target - arm_buffer                          |
//| Tepat di batas dihitung TRIGGER (>= / <=), bukan ditolak.         |
//+------------------------------------------------------------------+
bool IsArmTriggered(const int dir, const double price,
                    const double lock_target, const double arm_buffer)
{
   if(lock_target <= 0.0 || price <= 0.0)
      return false;
   if(RevExitIsBuy(dir))
      return (price >= lock_target + arm_buffer - REVEXIT_EPS);
   return (price <= lock_target - arm_buffer + REVEXIT_EPS);
}

//+------------------------------------------------------------------+
//| NextVirtualStop                                                  |
//| Ratchet stop virtual mengikuti harga berjalan.                    |
//|                                                                  |
//| current_vstop <= 0 berarti belum ada level (arming pertama):      |
//| kembalikan level mentah dari harga, caller yang menggabungkannya  |
//| dengan lock_target supaya profit minimum tetap terjamin.          |
//|                                                                  |
//| Sudah ada level: maju hanya bila lompatannya >= trail_step.       |
//| Kalau harga balik, level LAMA dipertahankan - tidak pernah mundur.|
//+------------------------------------------------------------------+
double NextVirtualStop(const int dir, const double price,
                       const double trail_dist, const double trail_step,
                       const double current_vstop, const double tick)
{
   if(price <= 0.0)
      return current_vstop;

   double step = (trail_step > 0.0) ? trail_step
                                    : ((tick > 0.0) ? tick : 0.0);
   double tol  = RevExitTol(tick);

   if(RevExitIsBuy(dir))
   {
      double raw = RevExitFloorToTick(price - trail_dist, tick);
      if(current_vstop <= 0.0)
         return raw;                                  // arming pertama
      if(raw >= current_vstop + step - tol)
         return raw;                                  // maju
      return current_vstop;                           // tahan / tidak mundur
   }

   double raw_sell = RevExitCeilToTick(price + trail_dist, tick);
   if(current_vstop <= 0.0)
      return raw_sell;
   if(raw_sell <= current_vstop - step + tol)
      return raw_sell;
   return current_vstop;
}

//+------------------------------------------------------------------+
//| IsVirtualStopHit                                                 |
//| BUY  : harga tutup (Bid) menyentuh atau menembus vstop ke bawah.  |
//| SELL : harga tutup (Ask) menyentuh atau menembus vstop ke atas.   |
//| Tepat di level dihitung KENA.                                     |
//+------------------------------------------------------------------+
bool IsVirtualStopHit(const int dir, const double price, const double vstop)
{
   if(vstop <= 0.0 || price <= 0.0)
      return false;
   if(RevExitIsBuy(dir))
      return (price <= vstop + REVEXIT_EPS);
   return (price >= vstop - REVEXIT_EPS);
}

//+------------------------------------------------------------------+
//| NetStopCandidate                                                 |
//| Kandidat SL server sebagai JARING PENGAMAN di belakang vstop.     |
//|                                                                  |
//| BUY  : min(vstop, floor(price - eff_min))                         |
//| SELL : max(vstop, ceil (price + eff_min))                         |
//|                                                                  |
//| eff_min adalah jarak minimum legal broker hasil hitung EA. Karena |
//| jaring harus lebih longgar dari vstop, hasilnya bisa terdorong    |
//| melewati breakeven basket. Kalau itu terjadi kandidat DIBATALKAN  |
//| (return 0): lebih baik tidak ada SL server sama sekali daripada   |
//| SL yang merugi. Eksekusi tetap dipegang trailing virtual.         |
//|                                                                  |
//| Return 0 juga bila vstop atau be belum valid.                     |
//+------------------------------------------------------------------+
double NetStopCandidate(const int dir, const double price, const double vstop,
                        const double be, const double eff_min, const double tick)
{
   if(vstop <= 0.0 || be <= 0.0 || price <= 0.0)
      return 0.0;

   double tol = RevExitTol(tick);

   if(RevExitIsBuy(dir))
   {
      double legal = RevExitFloorToTick(price - eff_min, tick);
      double net   = MathMin(vstop, legal);
      if(net <= 0.0)
         return 0.0;
      if(net < be - tol)
         return 0.0;          // jarak legal memaksa net di bawah BE
      return net;
   }

   double legal_sell = RevExitCeilToTick(price + eff_min, tick);
   double net_sell   = MathMax(vstop, legal_sell);
   if(net_sell <= 0.0)
      return 0.0;
   if(net_sell > be + tol)
      return 0.0;             // jarak legal memaksa net di atas BE
   return net_sell;
}

//+------------------------------------------------------------------+
//| IsStopDistanceLegal                                              |
//| Apakah level stop masih memenuhi jarak minimum dari harga?        |
//| Dipakai untuk memutuskan mengirim PositionModify atau tidak,      |
//| sehingga retcode 10016 dicegah sebelum request dikirim.           |
//+------------------------------------------------------------------+
bool IsStopDistanceLegal(const int dir, const double price, const double stop,
                         const double eff_min, const double tick)
{
   if(stop <= 0.0 || price <= 0.0)
      return false;
   double tol = RevExitTol(tick);
   if(RevExitIsBuy(dir))
      return (stop <= price - eff_min + tol);
   return (stop >= price + eff_min - tol);
}

#endif // REVENG_EXIT_MQH
//+------------------------------------------------------------------+
