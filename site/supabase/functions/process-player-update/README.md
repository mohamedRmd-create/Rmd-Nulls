# process-player-update

Edge Function لمعالجة طلبات تحديث بيانات اللاعب من صورتين.

## النشر

```bash
supabase functions deploy process-player-update
```

أو أنشئ/ارفع الدالة من Supabase Dashboard.

لا تضع `SUPABASE_SERVICE_ROLE_KEY` في الواجهة الأمامية. تستخدم الدالة المفتاح السري من بيئة Edge Function فقط.

## الوظيفة

1. تتحقق من جلسة اللاعب وملكية الطلب.
2. تقرأ الصورتين من bucket `verification-docs`.
3. تستخدم Tesseract.js لاستخراج النص والأرقام.
4. تصحح `I -> J` في Player Tag وتتحقق من مجموعة الأحرف `0289PYLQGRJCUV`.
5. تطبق قواعد التناقض وقفزة +15,000 كأس خلال أقل من 48 ساعة وانخفاض الانتصارات.
6. تقبل الطلب وتحدث `players` أو تعلّقه `pending_review` أو ترفضه.
7. تحفظ OCR والسبب في `verification_requests`.
