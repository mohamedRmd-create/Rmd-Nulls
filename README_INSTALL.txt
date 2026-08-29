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

FIXES IN THIS BUILD
- The supplied avatar/frame artwork is now rendered using its own transparent hex geometry; the old CSS hex clip-path is no longer applied to profile artwork.
- Frame previews use the full supplied frame canvas so the R badge, stars, lightning and flames are not cropped or replaced by an old/default hex.
- Frame selection previews the currently selected avatar underneath the frame, making avatar/frame compatibility visible before selection.
- The top account avatar and player-list avatars now use the selected profile image/frame instead of the old generic controller/hex icon.
- Appearance saving now gives a specific diagnostic message when the protected Supabase RPC has not been installed or the session has expired.
- The supplied SQL keeps appearance changes protected through the SECURITY DEFINER RPC; users can only change their own avatar/frame and cannot use this feature to modify rank, trophies, verification, or other player fields.

IMPORTANT FOR THE SAVE ERROR
After replacing the website files, run supabase_verification_setup.sql in the same Supabase project. The frontend intentionally uses the protected set_player_appearance RPC. If the SQL has not been executed, changing an appearance will fail and the page will tell you exactly what is missing.
