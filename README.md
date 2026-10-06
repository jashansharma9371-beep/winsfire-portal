# WinsFire Order Portal: deploy guide

A static site (no build tools needed) plus Supabase for database, login and image storage.

```
public/index.html       the whole app
public/config.js        your settings (or use Vercel environment variables)
supabase/schema_all.sql all database setup, run once
vercel.json             hosting + security headers
build.js                writes config.js from Vercel environment variables
push.sh                 helper to push to GitHub
```

## 1. Supabase (database)
1. supabase.com > New project (save the database password).
2. SQL Editor > New query > paste all of `supabase/schema_all.sql` > Run (once).
3. Project Settings > API: copy the **Project URL** and the **anon public** key. Never use the service_role key.
4. Optional for testing: Authentication > Providers > Email > turn off "Confirm email".

## 2. GitHub
```bash
cd winsfire-vercel
git init
git add .
git commit -m "WinsFire order portal"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/winsfire-portal.git
git push -u origin main
```
(Create an empty **private** repository named `winsfire-portal` on github.com first. Or run `./push.sh https://github.com/YOUR-USERNAME/winsfire-portal.git`.)
With the GitHub CLI instead: `gh repo create winsfire-portal --private --source=. --push`

## 3. Vercel
1. vercel.com > Add New > Project > import the GitHub repo. Leave the settings as detected (vercel.json sets them).
2. Before deploying, open **Environment Variables** and add:

| Name | Value |
|---|---|
| SUPABASE_URL | your Project URL |
| SUPABASE_ANON_KEY | your anon public key |
| COMPANY_NAME | WinsFire |
| CONTACT_EMAIL | your email |
| COMPANY_ADDRESS | your address |
| GRIEVANCE_CONTACT | contact for data requests |
| GOVERNING_LAW | India |
| LOGO_URL, BRAND_COLOR | optional |

3. Deploy. Or from a terminal: `npx vercel --prod`

## 4. Connect login to your live link
Supabase > Authentication > URL Configuration: set **Site URL** to your Vercel link and add it under **Redirect URLs**.

## 5. Make yourself admin
Open your live link, create an account, then in Supabase SQL Editor run (use your email):
```sql
update public.profiles set role = 'admin', approved = true where email = 'you@yourcompany.com';
```
Reload, sign in, open **Admin**, add products and approve your staff.

## Notes
- Edit settings later by changing Environment Variables in Vercel and redeploying.
- The page loads Tailwind from a CDN, so it works with no build step. For maximum speed later, switch to a compiled Tailwind stylesheet.
- Legal pages are templates. Have them checked against your local laws.
`fix deploy 404
