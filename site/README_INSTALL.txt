

=== آخر تعديل: إعدادات اللاعبين ===
تمت إضافة قسم إعدادات اللاعبين إلى admin.html. يجب تشغيل ملف supabase_verification_setup.sql (أو تنفيذ الجزء الجديد الخاص بالدالة admin_update_player_data) في Supabase SQL Editor مرة واحدة.


Appearance v4: six clean no-frame profile images are in assets/avatars/*-empty.png. The clean image is shown when no frame is selected. The appearance picker renders even if the Supabase appearance query fails.


=== تحديث معلومات اللاعبين عبر صورتين + OCR ===
تمت إضافة زر "تحديث المعلومات" في صفحة النظرة العامة. اللاعب يرفع صورتين إلى bucket `verification-docs`، ثم تستدعي الواجهة Edge Function باسم `process-player-update`.

الملفات الجديدة:
- `supabase/functions/process-player-update/index.ts` — OCR + منطق كشف التلاعب + تحديث players عند القبول.
- `supabase/functions/process-player-update/deno.json` — اعتماديات Edge Function.

مهم: يجب نشر Edge Function في Supabase قبل اختبار التحديث الآلي. متغيرات `SUPABASE_URL` و`SUPABASE_ANON_KEY` و`SUPABASE_SERVICE_ROLE_KEY` متاحة تلقائيًا في Edge Functions في Supabase؛ لا تضع service_role key داخل `index.html`.

نفّذ `supabase_verification_setup.sql` في SQL Editor أولًا، ثم انشر Edge Function. الفحص يستخدم Tesseract.js 5.1.1 ويخزّن نتيجة OCR الخام والقرار في `verification_requests.ocr_extracted_json` و`auto_decision` و`auto_decision_reason`.

إذا تعذر تشغيل OCR في بيئة Edge بسبب توافق حزمة Tesseract، سيبقى الطلب محفوظًا في لوحة الإدارة بدل فقدانه، ويمكن للمشرف مراجعته يدويًا.
