-- ============================================================
-- WinsFire portal: ALL database setup in one file (parts 1 to 4).
-- Supabase > SQL Editor > New query > paste everything > Run. Run it ONCE.
-- ============================================================

-- ################ PART: schema.sql ################
-- WinsFire internal ordering portal. Paste into Supabase > SQL Editor > Run.

-- 1. Tables ------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  role text not null default 'employee' check (role in ('admin','employee')),
  approved boolean not null default false,          -- new sign-ups wait for admin approval
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 120),
  sku text not null unique check (char_length(sku) between 1 and 40),
  price numeric(12,2) not null check (price >= 0),
  stock int not null default 0 check (stock >= 0),
  category text not null default 'General',
  description text default '',
  image_url text,
  rating numeric(2,1) check (rating between 0 and 5),
  created_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  total_items int not null,
  total_value numeric(14,2) not null,
  status text not null default 'Pending' check (status in ('Pending','Approved','Dispatched','Rejected')),
  delivery_location text default '',
  created_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  quantity int not null check (quantity between 1 and 1000),
  unit_price numeric(12,2) not null
);

-- 2. New user -> profile (role employee, not approved) -----------------
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, left(coalesce(new.raw_user_meta_data->>'full_name',''), 80));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 3. Helpers -------------------------------------------------------------
create function public.is_member() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and approved) $$;
create function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and approved and role = 'admin') $$;

-- 4. Place an order: prices and stock are checked on the server ----------
create function public.place_order(items jsonb, location text default '') returns uuid
language plpgsql security definer set search_path = public as $$
declare oid uuid; it jsonb; p products%rowtype; q int; ti int := 0; tv numeric := 0;
begin
  if not is_member() then raise exception 'Your account is not approved yet'; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) not between 1 and 50 then
    raise exception 'Your basket is empty or too large'; end if;
  insert into orders (user_id, total_items, total_value, delivery_location)
    values (auth.uid(), 0, 0, left(coalesce(location,''), 200)) returning id into oid;
  for it in select value from jsonb_array_elements(items) loop
    q := (it->>'quantity')::int;
    if q is null or q < 1 or q > 1000 then raise exception 'Invalid quantity'; end if;
    select * into p from products where id = (it->>'product_id')::uuid for update;
    if not found then raise exception 'A product in your basket no longer exists'; end if;
    if p.stock < q then raise exception 'Not enough stock for %', p.name; end if;
    update products set stock = stock - q where id = p.id;
    insert into order_items (order_id, product_id, product_name, quantity, unit_price)
      values (oid, p.id, p.name, q, p.price);
    ti := ti + q; tv := tv + q * p.price;
  end loop;
  update orders set total_items = ti, total_value = tv where id = oid;
  return oid;
end $$;

-- 5. Change order status (admin only). Rejecting returns stock. -----------
create function public.set_order_status(oid uuid, new_status text) returns void
language plpgsql security definer set search_path = public as $$
declare old text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if new_status not in ('Pending','Approved','Dispatched','Rejected') then raise exception 'Invalid status'; end if;
  select status into old from orders where id = oid for update;
  if old is null then raise exception 'Order not found'; end if;
  if new_status = 'Rejected' and old <> 'Rejected' then
    update products p set stock = p.stock + oi.q
      from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
      where p.id = oi.product_id;
  elsif old = 'Rejected' and new_status <> 'Rejected' then
    if exists (select 1 from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
               join products p on p.id = oi.product_id where p.stock < oi.q) then
      raise exception 'Not enough stock to reopen this order'; end if;
    update products p set stock = p.stock - oi.q
      from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
      where p.id = oi.product_id;
  end if;
  update orders set status = new_status where id = oid;
end $$;

-- 6. Row Level Security: the real lock on your data ------------------------
alter table public.profiles    enable row level security;
alter table public.products    enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;

create policy "own profile or admin" on public.profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy "admin edits profiles" on public.profiles for update to authenticated using (is_admin()) with check (is_admin());

create policy "members view products" on public.products for select to authenticated using (is_member());
create policy "admin adds products"    on public.products for insert to authenticated with check (is_admin());
create policy "admin edits products"   on public.products for update to authenticated using (is_admin()) with check (is_admin());
create policy "admin deletes products" on public.products for delete to authenticated using (is_admin());

create policy "own orders or admin" on public.orders for select to authenticated using (user_id = auth.uid() or is_admin());
create policy "own order items or admin" on public.order_items for select to authenticated
  using (exists (select 1 from orders o where o.id = order_id and (o.user_id = auth.uid() or is_admin())));
-- No insert/update policies on orders: orders can only be created through place_order() and changed through set_order_status().

-- 7. Lock out anonymous (not signed in) visitors -------------------------
revoke all on all tables in schema public from anon;
revoke execute on function public.place_order(jsonb, text), public.set_order_status(uuid, text), public.is_member(), public.is_admin() from public, anon;
grant  execute on function public.place_order(jsonb, text), public.set_order_status(uuid, text), public.is_member(), public.is_admin() to authenticated;

-- 8. Product image storage (2 MB, JPG/PNG/WebP, only admins can upload) ---
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "anyone views product images" on storage.objects for select using (bucket_id = 'product-images');
create policy "admin uploads images" on storage.objects for insert to authenticated with check (bucket_id = 'product-images' and public.is_admin());
create policy "admin updates images" on storage.objects for update to authenticated using (bucket_id = 'product-images' and public.is_admin());
create policy "admin deletes images" on storage.objects for delete to authenticated using (bucket_id = 'product-images' and public.is_admin());

-- 9. MAKE YOURSELF ADMIN: sign up in the app first, then run this with your email.
-- update public.profiles set role = 'admin', approved = true where email = 'you@yourcompany.com';

-- ################ PART: schema_v2.sql ################
-- WinsFire portal upgrade. Run AFTER schema.sql (Supabase > SQL Editor > Run).

alter table public.orders   add column if not exists note text default '';
alter table public.products add column if not exists low_stock_at int not null default 10 check (low_stock_at >= 0);

alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('Pending','Approved','Dispatched','Rejected','Cancelled'));

-- Place an order, now with an optional note
drop function if exists public.place_order(jsonb, text);
create function public.place_order(items jsonb, location text default '', order_note text default '') returns uuid
language plpgsql security definer set search_path = public as $$
declare oid uuid; it jsonb; p products%rowtype; q int; ti int := 0; tv numeric := 0;
begin
  if not is_member() then raise exception 'Your account is not approved yet'; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) not between 1 and 50 then
    raise exception 'Your basket is empty or too large'; end if;
  insert into orders (user_id, total_items, total_value, delivery_location, note)
    values (auth.uid(), 0, 0, left(coalesce(location,''), 200), left(coalesce(order_note,''), 300)) returning id into oid;
  for it in select value from jsonb_array_elements(items) loop
    q := (it->>'quantity')::int;
    if q is null or q < 1 or q > 1000 then raise exception 'Invalid quantity'; end if;
    select * into p from products where id = (it->>'product_id')::uuid for update;
    if not found then raise exception 'A product in your basket no longer exists'; end if;
    if p.stock < q then raise exception 'Not enough stock for %', p.name; end if;
    update products set stock = stock - q where id = p.id;
    insert into order_items (order_id, product_id, product_name, quantity, unit_price)
      values (oid, p.id, p.name, q, p.price);
    ti := ti + q; tv := tv + q * p.price;
  end loop;
  update orders set total_items = ti, total_value = tv where id = oid;
  return oid;
end $$;

-- Employees can cancel their own Pending requests (stock goes back)
create function public.cancel_order(oid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype;
begin
  select * into o from orders where id = oid for update;
  if not found or (o.user_id <> auth.uid() and not is_admin()) then raise exception 'Order not found'; end if;
  if o.status <> 'Pending' then raise exception 'Only pending requests can be cancelled'; end if;
  update products p set stock = p.stock + oi.q
    from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
    where p.id = oi.product_id;
  update orders set status = 'Cancelled' where id = oid;
end $$;

-- Admin status changes, aware of Cancelled orders
create or replace function public.set_order_status(oid uuid, new_status text) returns void
language plpgsql security definer set search_path = public as $$
declare old text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if new_status not in ('Pending','Approved','Dispatched','Rejected') then raise exception 'Invalid status'; end if;
  select status into old from orders where id = oid for update;
  if old is null then raise exception 'Order not found'; end if;
  if new_status = 'Rejected' and old not in ('Rejected','Cancelled') then
    update products p set stock = p.stock + oi.q
      from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
      where p.id = oi.product_id;
  elsif old in ('Rejected','Cancelled') and new_status <> 'Rejected' then
    if exists (select 1 from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
               join products p on p.id = oi.product_id where p.stock < oi.q) then
      raise exception 'Not enough stock to reopen this order'; end if;
    update products p set stock = p.stock - oi.q
      from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
      where p.id = oi.product_id;
  end if;
  update orders set status = new_status where id = oid;
end $$;

revoke execute on function public.place_order(jsonb, text, text), public.cancel_order(uuid) from public, anon;
grant  execute on function public.place_order(jsonb, text, text), public.cancel_order(uuid) to authenticated;

-- ################ PART: schema_v3.sql ################
-- WinsFire portal upgrade 3. Run AFTER schema.sql and schema_v2.sql.

alter table public.profiles add column if not exists phone text;
alter table public.products add column if not exists rating_count int not null default 0;

-- Sign-up now also saves an optional phone number
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, phone)
  values (new.id, new.email, left(coalesce(new.raw_user_meta_data->>'full_name',''), 80),
          left(coalesce(new.raw_user_meta_data->>'phone',''), 20));
  return new;
end $$;

-- ---------- Staff reviews (only after an order for that product is Dispatched) ----------
create table public.product_reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  author_name text not null,
  rating int not null check (rating between 1 and 5),
  comment text default '' check (char_length(comment) <= 500),
  created_at timestamptz not null default now(),
  unique (product_id, user_id)
);
alter table public.product_reviews enable row level security;
create policy "members read reviews" on public.product_reviews for select to authenticated using (is_member());
create policy "admin deletes reviews" on public.product_reviews for delete to authenticated using (is_admin());

create function public.rate_product(pid uuid, stars int, review text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_member() then raise exception 'Your account is not approved yet'; end if;
  if stars is null or stars not between 1 and 5 then raise exception 'Choose 1 to 5 stars'; end if;
  if not exists (select 1 from order_items oi join orders o on o.id = oi.order_id
                 where oi.product_id = pid and o.user_id = auth.uid() and o.status = 'Dispatched') then
    raise exception 'You can review a product after your order for it is dispatched';
  end if;
  insert into product_reviews (product_id, user_id, author_name, rating, comment)
  select pid, auth.uid(), coalesce(nullif(full_name,''), 'Staff member'), stars, left(coalesce(review,''), 500)
  from profiles where id = auth.uid()
  on conflict (product_id, user_id) do update set rating = excluded.rating, comment = excluded.comment, created_at = now();
  update products set
    rating = (select round(avg(rating)::numeric, 1) from product_reviews where product_id = pid),
    rating_count = (select count(*) from product_reviews where product_id = pid)
  where id = pid;
end $$;

-- ---------- In-app notifications ----------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  message text not null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.notifications enable row level security;
create policy "own notifications" on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "mark own read" on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke update on public.notifications from authenticated;
grant update (read) on public.notifications to authenticated;     -- they can only flip "read"

-- Admin status changes now notify the employee
create or replace function public.set_order_status(oid uuid, new_status text) returns void
language plpgsql security definer set search_path = public as $$
declare old text; owner uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if new_status not in ('Pending','Approved','Dispatched','Rejected') then raise exception 'Invalid status'; end if;
  select status, user_id into old, owner from orders where id = oid for update;
  if old is null then raise exception 'Order not found'; end if;
  if new_status = 'Rejected' and old not in ('Rejected','Cancelled') then
    update products p set stock = p.stock + oi.q
      from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
      where p.id = oi.product_id;
  elsif old in ('Rejected','Cancelled') and new_status <> 'Rejected' then
    if exists (select 1 from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
               join products p on p.id = oi.product_id where p.stock < oi.q) then
      raise exception 'Not enough stock to reopen this order'; end if;
    update products p set stock = p.stock - oi.q
      from (select product_id, sum(quantity) q from order_items where order_id = oid group by product_id) oi
      where p.id = oi.product_id;
  end if;
  update orders set status = new_status where id = oid;
  if old <> new_status then
    insert into notifications (user_id, message)
    values (owner, 'Your request WF-' || upper(left(oid::text, 8)) || ' is now ' || new_status);
  end if;
end $$;

revoke all on public.product_reviews, public.notifications from anon;
revoke execute on function public.rate_product(uuid, int, text) from public, anon;
grant  execute on function public.rate_product(uuid, int, text) to authenticated;

-- ################ PART: schema_v4.sql ################
-- WinsFire portal upgrade 4: ratings can only come from real staff reviews.
-- Run AFTER schema.sql, schema_v2.sql and schema_v3.sql.

create or replace function public.guard_rating() returns trigger
language plpgsql as $$
begin
  -- Browser users (even admins) cannot set or change ratings directly.
  -- Only rate_product() (which runs as the database owner) can.
  if current_user in ('authenticated','anon') then
    if tg_op = 'INSERT' then
      new.rating := null; new.rating_count := 0;
    else
      new.rating := old.rating; new.rating_count := old.rating_count;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists products_guard_rating on public.products;
create trigger products_guard_rating before insert or update on public.products
  for each row execute function public.guard_rating();

-- Remove any hand-typed ratings that are not backed by real reviews
update public.products set rating = null where rating_count = 0;
