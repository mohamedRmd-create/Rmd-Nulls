Rmd Null - appearance + badge management update

WHAT WAS UPDATED
- Replaced the profile appearance catalog with the six supplied cartoon-style hexagonal avatars.
- Added the supplied five illustrated hexagonal frames.
- Kept the basic controller avatar as the default; unused supplied avatars (pirate skull and ninja) are locked.
- Kept the Masters frame locked until a future unlock rule is assigned.
- Updated badge rewards:
  * بطل الموسم -> لقب المحترف + الإطار الفضي
  * ألف انتصار -> لقب محارب الألف
  * أسطورة الحلبة -> الإطار الماسي + صورة حامل علم القراصنة
  * صياد النجوم -> لقب صياد النجوم + الإطار البرونزي
  * قلعة لا تُقهر -> لقب حامي القلعة
  * سرعة البرق -> لقب فلاش + صورة فارس الشاي + الإطار الذهبي
  * ملك السحب -> لا لقب ولا إطار ولا صورة
  * قائد الكلان -> لقب القائد + الإطار الماسي + صورة الدجاجة الملكية
- Added a reward box to badge details.
- Added admin-only ability to remove a specific badge from a specific player.
- Removing a badge also resets a cosmetic that was unlocked only by that badge when appropriate.
- Strengthened badge display so the same badge is rendered only once per player.
- Kept the existing responsive player/profile UI and appearance picker.

SUPABASE SQL
1. Open Supabase -> SQL Editor.
2. Run the supplied supabase_verification_setup.sql after backing up/confirming your current schema.
3. The script includes the new admin_remove_badge RPC and updated cosmetic unlock rules.

IMPORTANT
- Do not put a Supabase service-role key in the frontend.
- The admin badge-removal action is protected by public.is_admin().
- The site expects the existing Supabase tables used by the previous Rmd Null build.

FILES
- index.html
- admin.html
- supabase_verification_setup.sql
- assets/avatars/*.png (new supplied avatar artwork)
- assets/frames/frame-*.png (new supplied frame artwork)
- Existing SVG assets are retained for compatibility but are no longer used for the new appearance catalog.


CLANS UPDATE
============
هذه النسخة تضيف نظام الكلانات المرتبط بجدول public.clans.
شغّل فقط الجزء الخاص بالكلانات في supabase_verification_setup.sql (الجزء الذي يبدأ بـ:
-- 15) Clans
ولا تعِد تشغيل الملف كاملًا إذا كانت قاعدة البيانات الحالية تعمل.
بعد إنشاء الجدول، ارفع index.html وadmin.html.
يمكن للمشرف إضافة/تعديل/حذف الكلانات من لوحة الإدارة.
