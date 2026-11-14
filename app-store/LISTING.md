# App Store başvuru dosyası — Operation Windfall

Paket kimliği (Bundle ID): `com.operationwindfall.app` · Sürüm: 1.0.1 (derleme 1) · Yalnızca iPhone, yatay ekran · En düşük iOS 15.0 · Takım: ZP6DN8JZX7

## Yüklenecek dosyalar (bu klasörde)

| Dosya | Nereye |
| --- | --- |
| `operation-windfall-1.0.1.ipa` | App Store Connect'e yüklenecek imzalı paket (Transporter ya da Xcode ile) |
| `screenshots/iphone-6.9/1-menu.png`, `2-takeoff.png`, `3-flight.png` (2868×1320) | iPhone 6,9" ekran görüntüleri (diğer iPhone boyutları bundan otomatik ölçeklenir) |

Uygulama simgesi paketin içindedir; ayrıca yüklenmez.

## Mağaza metinleri

**Ad (30):** Operation Windfall
**Kategori:** Oyunlar → Aksiyon (ikincil: Simülasyon) · **Fiyat:** Ücretsiz
**Gizlilik politikası URL'si:** https://operation-windfall.vercel.app/privacy
**Destek URL'si:** https://operation-windfall.vercel.app

### English (birincil dil)
**Alt başlık (30):** WWII carrier air combat
**Tanıtım metni (170):** Take off from a pitching carrier deck, fight your way to the target and bring the aircraft home. Seven sorties, a live ranking and a shared sky.
**Anahtar kelimeler (100):** ww2,air combat,dogfight,flight,plane,carrier,bomber,pilot,arcade,war,fighter,squadron
**Açıklama:** `play-store/LISTING.md` içindeki English tam açıklama ile aynı.

### Türkçe
**Alt başlık:** 2. Dünya Savaşı hava muharebesi
**Tanıtım metni:** Sallanan uçak gemisinden kalk, hedefe kadar savaş ve uçağını eve getir. Yedi sorti, canlı sıralama ve ortak gökyüzü.
**Anahtar kelimeler:** savaş,uçak,hava muharebesi,it dalaşı,pilot,uçak gemisi,bombardıman,arcade,filo,uçuş
**Açıklama:** `play-store/LISTING.md` içindeki Türkçe tam açıklama ile aynı.

### Deutsch
**Alt başlık:** Luftkampf im 2. Weltkrieg
**Tanıtım metni:** Starte vom schwankenden Trägerdeck, kämpfe dich zum Ziel durch und bring die Maschine nach Hause. Sieben Einsätze, Rangliste und gemeinsamer Himmel.
**Anahtar kelimeler:** luftkampf,flugzeug,weltkrieg,pilot,flugzeugträger,bomber,arcade,staffel,jagdflieger,krieg
**Açıklama:** `play-store/LISTING.md` içindeki Deutsch tam açıklama ile aynı.

## App Store Connect beyanları için önerilen yanıtlar

Bunlar senin adına verilen yasal beyanlardır; göndermeden önce oku.

- **Yaş derecelendirmesi:** Çizgi film / fantastik şiddet: seyrek-hafif. Gerçekçi şiddet: seyrek-hafif (uçak, gemi, araç ve uzaktan görünen asker figürleri vurulur; kan yok). Diğer tüm başlıklar: yok. Kumar, sınırsız web erişimi, kullanıcı içeriği/sohbet: hayır.
- **Uygulama gizliliği (App Privacy):** Veri toplanıyor: evet. Takip (tracking) için kullanılmıyor.
  - *Tanımlayıcılar → Kullanıcı kimliği* (rastgele hesap numarası): uygulama işlevselliği, kullanıcıyla ilişkili.
  - *İletişim bilgileri → Ad* (pilot takma adı; yalnızca yarışmaya katılırsan): uygulama işlevselliği, kullanıcıyla ilişkili.
  - *Kullanım verileri → Ürün etkileşimi* ve *Kullanıcı içeriği → Oyun içeriği* (puanlar, sortiler): uygulama işlevselliği, kullanıcıyla ilişkili.
- **Dışa aktarım uyumluluğu (şifreleme):** Pakette `ITSAppUsesNonExemptEncryption = false` ayarlı; yalnızca standart HTTPS kullanılıyor, ek soru çıkmaz.
- **Giriş bilgisi:** Gerekmiyor. İnceleme notu önerisi: "No account or sign-in is required. Tap TAKE OFF on the menu to start a sortie. Entering a pilot name is optional and only joins the online ranking; the pilot and all its data can be deleted from the same menu."
- **Reklam / IDFA:** Yok. **Uygulama içi satın alma:** Yok (ileride eklenirse Apple'ın uygulama içi satın alma sistemi zorunlu).
- **İçerik hakları:** Üçüncü taraf içerik yok.

## Başvuru adımları

1. https://appstoreconnect.apple.com → Uygulamalar → **+ Yeni Uygulama**: platform iOS, ad "Operation Windfall", birincil dil English (U.S.), paket kimliği `com.operationwindfall.app`, SKU `operation-windfall`.
2. Paketi yükle: Mac'te **Transporter** uygulamasına `.ipa` dosyasını sürükle ve "Deliver" de.
3. Sürüm sayfasında metinleri ve ekran görüntülerini gir, yüklenen derlemeyi seç.
4. Uygulama gizliliği, yaş derecelendirmesi, fiyat ve bulunabilirlik bölümlerini doldur.
5. **İncelemeye gönder.** İstersen önce TestFlight ile kendi telefonunda dene.

## Paketi yeniden üretmek

`app/build-ios.sh` çalıştır (Xcode ve geliştirici hesabı gerekir). Aynı sürümü tekrar yükleyeceksen önce `app/ios/App/App.xcodeproj/project.pbxproj` içindeki `CURRENT_PROJECT_VERSION` değerini artır.

## Bilinen notlar

- İlk sürüm yalnızca iPhone; iPad'de uyumluluk modunda çalışır. Yerel iPad desteği sonraki sürüme bırakıldı.
- Oyun dosyaları pakete gömülü: oyundaki her değişiklik yeni bir App Store sürümü gerektirir.
