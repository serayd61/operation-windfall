# Gizlilik beyanı taslağı: geri bildirim özelliği

Oyundaki "Geri bildirim gönder" düğmesi şunları sunucuya (Supabase) yollar:
oyuncunun yazdığı metin (en çok 1000 karakter), oyun dili, sürüm numarası,
ekran boyutu ve tarayıcı/cihaz bilgisinin (user agent) ilk 150 karakteri.
Kayıt, oyuncunun hesap kimliğiyle birlikte tutulur. Reklam ya da izleme için
kullanılmaz, üçüncü tarafla paylaşılmaz.

Aşağıdakileri mağaza panellerinde sen işaretlersin; mevcut beyanlara ek olarak girilir.

## App Store Connect → App Privacy

| Veri türü | Seçim |
|---|---|
| User Content → **Other User Content** | Toplanıyor |
| Diagnostics → **Other Diagnostic Data** (cihaz/ekran bilgisi) | Toplanıyor |

Her ikisi için:
- Amaç: **App Functionality** (istersen ek olarak Product Personalization değil, yalnızca bu)
- Kullanıcıya bağlı mı: **Evet** (hesap kimliğiyle saklanıyor)
- İzleme (tracking) için kullanılıyor mu: **Hayır**

## Google Play Console → Uygulama içeriği → Veri güvenliği

| Veri türü | Seçim |
|---|---|
| Uygulama etkinliği → **Kullanıcı tarafından oluşturulan diğer içerikler** | Toplanıyor, paylaşılmıyor |
| Uygulama bilgileri ve performansı → **Teşhis** | Toplanıyor, paylaşılmıyor |

Her ikisi için:
- Geçici olarak mı işleniyor: **Hayır** (saklanıyor)
- Zorunlu mu: **İsteğe bağlı** (oyuncu yalnızca kendi isteğiyle gönderir)
- Amaç: **Uygulama işlevselliği**, **Analiz** (hata ayıklama için)
- Aktarım sırasında şifreleniyor: **Evet**
- Silme talebi: hesap silme yolu zaten beyan edildiyse aynısı geçerli

## Gizlilik sayfası (privacy.html)

Sayfada geri bildirim maddesi zaten var (metin, pilot adı, dil, sürüm, cihaz türü;
pilotla birlikte silinir). Değişiklik gerekmiyor; mağaza beyanları bu maddeyle
aynı şeyi söylemeli.
