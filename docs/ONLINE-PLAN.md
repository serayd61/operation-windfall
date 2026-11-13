# Operation Windfall — çevrimiçi platform planı

Amaç: puanın ve ekipmanın değer taşıdığı, güvenilir bir yarışma platformu. Durum: build 17.

## 1. Kuruldu (build 15–17)

| Alan | Ne var |
| --- | --- |
| Kimlik | Pilot adıyla tek adımda katılma (anonim hesap). Ad kuralları: 3–16 karakter, ayrılmış ve saldırgan adlar reddedilir. |
| Hesap kurtarma | Tek kullanımlık kurtarma kodu: pilot başka cihaza taşınır, eski cihaz pilotu kaybeder. Saatte 5 deneme sınırı. |
| Puan bütünlüğü | Her sorti sunucuda açılır (`start_sortie`). Puan yalnızca o sorti için, bir kez ve geçen gerçek süreyle uyumluysa kabul edilir (`submit_score`). |
| Ekonomi | Puan, yükseltme ve uçak yalnızca sunucu fonksiyonlarıyla değişir. Her hareket `ledger` tablosuna yazılır. `tokens` alanı ücretli para birimi için ayrıldı. |
| Yarışma | Genel, haftalık (Pazartesi başlar, UTC) ve sorti bazlı sıralama. |
| Birlikte oyun | Ortak gökyüzü, filo kodu, davet bağlantısı, filo lobisi (kim çevrimiçi, hangi sortide). Canlı kanallar yalnızca katılmış pilotlara açık. |
| Moderasyon | `pilots.banned`: askıya alınan pilot sıralamadan düşer, puan gönderemez, alışveriş yapamaz, canlı kanallara giremez. |
| Gizlilik | Gizlilik sayfası (EN/TR/DE), oyun içinden kalıcı hesap silme. Veri AB'de (Frankfurt). |
| Dayanıklılık | Sunucu yokken oyun misafir modunda çalışır; puan gönderimi 3 kez yeniden denenir. |

## 2. Para girmeden önce yapılması gerekenler

1. **Kalıcı hesap**: e-posta ya da Apple/Google ile giriş. Kendi e-posta gönderim hizmeti (SMTP) gerekir.
2. **Ödeme**: Stripe (web) ve mağaza içi satın alma (iOS/Android). Token yalnızca ödeme sağlayıcısının sunucudan sunucuya onayıyla yazılır; `ledger` zaten hazır.
3. **Hile karşıtı ikinci katman**: puan tavanları sorti başına ayarlanmalı, şüpheli kayıtlar için otomatik işaretleme ve inceleme ekranı.
4. **Bot koruması**: katılma adımına CAPTCHA (Cloudflare Turnstile ya da hCaptcha).
5. **Hukuk**: kullanım şartları, işletmeci iletişim bilgisi, iade koşulları, yaş sınırı.
6. **Yönetim paneli**: pilot arama, askıya alma, puan silme, ledger görüntüleme.

## 3. Oyun değeri (sonraki adımlar)

- Sezonlar ve sezon ödülleri (haftalık sıralamanın üstüne).
- Filo (takım) sıralaması, kalıcı filolar.
- Gerçek ortak görevler: düşmanların da paylaşıldığı sortiler (yetkili sunucu ya da ev sahibi oyuncu gerekir).
- Oyuncular arası düello (PvP) — gecikme telafisi ve hile riski nedeniyle en son.
- Bildirim ve arkadaş listesi.

## 4. İşletme

- Supabase ücretsiz planı 7 gün kullanılmazsa projeyi duraklatır ve yedek almaz; yayına çıkmadan önce ücretli plana geçilmeli.
- Canlı bağlantı sınırı ücretsiz planda aynı anda 200 istemcidir.
- Her sürümde: `supabase db lint`, `supabase db advisors`, iki tarayıcılı duman testi.
