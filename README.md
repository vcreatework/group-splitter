# Group Splitter: setup (about 10 minutes, all free)

Files: `index.html` (the whole website) and `setup.sql` (the database).

## 1. Supabase (free database)
1. Sign up at https://supabase.com and click **New project** (Free plan).
2. Open **SQL Editor > New query**, paste all of `setup.sql`, click **Run**.
3. Open **Project Settings > API** and copy the **Project URL** and the **anon public** key.
4. In `index.html`, fill in the two lines near the bottom:
   ```js
   const SUPABASE_URL = "https://xxxx.supabase.co";
   const SUPABASE_ANON_KEY = "eyJ...";
   ```
   The anon key is meant to be public. The database only lets visitors read the list
   and add students through the safe function; they cannot edit or delete.

## 2. GitHub Pages (free hosting)
1. On GitHub, create a new **public** repository, e.g. `group-splitter`.
2. **Add file > Upload files**, upload `index.html`, commit.
3. **Settings > Pages**: Source = *Deploy from a branch*, Branch = `main`, folder `/ (root)`, Save.
4. After about a minute the site is at `https://vcreatework.github.io/group-splitter/`.

## How it works
- Each new student goes into the lowest-numbered group with fewer than 3 people, or a new
  group if all are full. This happens in the database, so two people adding at the same
  moment still never make a group of 4.
- Every open copy of the page updates live.
- **Copy all numbers** copies the group's phone numbers, separated by commas.
- Each student has a **Copy number** button that copies just their number.
- The search box finds a group: type part of a phone number (`077...` or `+94 77...` both work) or a group number.
- Each phone number can register only once (`077...` and `+94 77...` count as the same).

## Admin view
Everyone with the link sees all groups. To import from Excel, open the site with `?admin` at the end
(`https://vcreatework.github.io/group-splitter/?admin`) and enter the admin password.
The password is stored only as a salted hash in the database (schema `gs_private`), not in this repo.

### Importing from Excel
In the admin view, an **Import from Excel** box appears. Pick an .xlsx file with a name column and a
phone column (a title above the header row is fine). 9-digit numbers get +94 added. Each row shows
"Will add" or why it's skipped (already registered, listed twice, no name, or not a valid Sri Lankan
mobile), and nothing is saved until you click **Add N students**.

## Removing a student
Students can tap **Remove me** on their own entry, which shows only in the browser they added
themselves from. The seat frees up and they can add themselves again. Students who were imported
from Excel or added by you have no Remove me button; delete them yourself as below.
 or starting over
Supabase > **Table Editor > students**: delete a row there. The freed seat is filled by the
next student added. To reset everything, run `truncate public.students restart identity;`
in the SQL Editor.

Without keys the page runs in demo mode, saving only in your own browser.

Note: Supabase pauses free projects after 7 days with no activity. Open the dashboard and
click **Restore** if that happens; your data is kept.
