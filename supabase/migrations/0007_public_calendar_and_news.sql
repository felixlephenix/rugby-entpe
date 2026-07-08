-- Rend le calendrier et les actus publiques (accessibles sans connexion), en élargissant
-- les policies SELECT existantes à anon. Les écritures restent réservées aux admins.

drop policy if exists "events readable by authenticated" on events;
create policy "events publicly readable"
  on events for select to anon, authenticated using (true);

drop policy if exists "match_details readable by authenticated" on match_details;
create policy "match_details publicly readable"
  on match_details for select to anon, authenticated using (true);

drop policy if exists "published news readable by authenticated, drafts admin-only" on news;
create policy "published news publicly readable, drafts admin-only"
  on news for select to anon, authenticated using (status = 'published' or is_admin());

drop policy if exists "news_photos readable when parent news is readable" on news_photos;
create policy "news_photos publicly readable when parent news is readable"
  on news_photos for select to anon, authenticated
  using (
    exists (
      select 1 from news n
      where n.id = news_photos.news_id
        and (n.status = 'published' or is_admin())
    )
  );
