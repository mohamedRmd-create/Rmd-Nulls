Rmd Null - latest site update

WHAT WAS UPDATED
- Added a "الصور والإطارات" section inside the account menu, above verification.
- Added original cartoon-style hexagonal profile avatars and lightweight profile frames.
- Added badge-based unlocks for selected avatars/frames.
- Added badge icons between player name and clan in the Players table.
- Added duplicate protection for player badges/titles.
- Added manual player ranks: Bronze, Silver, Gold, Diamond, Masters.
- Added an admin rank-management panel.
- Enhanced the player profile card and badge area.

IMPORTANT: SUPABASE SQL
1. Open Supabase -> SQL Editor.
2. Run the complete file: supabase_verification_setup.sql
3. Do this before uploading/testing the updated index.html/admin.html.

FILES
- index.html
- admin.html
- supabase_verification_setup.sql
- assets/avatars/*.svg
- assets/frames/*.svg

The site uses only the existing Supabase URL/anon key in the frontend. No service-role secret is included.
