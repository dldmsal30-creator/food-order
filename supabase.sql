-- Run this complete script in Supabase Dashboard → SQL Editor.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.app_settings (
  id integer primary key default 1 check (id = 1),
  event_name text not null default '스시X가리아 일일호프',
  bank_name text not null default '토스뱅크',
  account_number text not null default '1002-7989-3300',
  account_holder text not null default '',
  updated_at timestamptz not null default now()
);
insert into public.app_settings(id, event_name, bank_name, account_number) values (1, '스시X가리아 일일호프', '토스뱅크', '1002-7989-3300') on conflict (id) do update set bank_name=excluded.bank_name, account_number=excluded.account_number, updated_at=now();

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.menu_inventory (
  item_name text primary key,
  quantity_limit integer not null check (quantity_limit >= 0),
  quantity_sold integer not null default 0 check (quantity_sold >= 0 and quantity_sold <= quantity_limit),
  updated_at timestamptz not null default now()
);
-- Keep the previous limited-set sales count when the set receives its new menu name.
update public.menu_inventory old_item
set item_name = '할로윈 ! special ! 세트', quantity_limit = 60
where old_item.item_name = '할로윈 특가 · 2인'
  and not exists (select 1 from public.menu_inventory new_item where new_item.item_name = '할로윈 ! special ! 세트');
update public.menu_inventory new_item
set quantity_sold = least(new_item.quantity_limit, new_item.quantity_sold + old_item.quantity_sold),
    quantity_limit = 60, updated_at = now()
from public.menu_inventory old_item
where new_item.item_name = '할로윈 ! special ! 세트'
  and old_item.item_name = '할로윈 특가 · 2인';
delete from public.menu_inventory where item_name = '할로윈 특가 · 2인';
insert into public.menu_inventory(item_name,quantity_limit,quantity_sold)
values ('할로윈 ! special ! 세트',60,0) on conflict (item_name) do update set quantity_limit=60;
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  access_token_hash text not null unique,
  created_at timestamptz not null default now(),
  table_number text not null,
  customer_name text not null default '',
  request_note text not null default '',
  special_drink_choice text not null default '',
  total_amount integer not null check(total_amount >= 0),
  payment_status text not null default '입금 대기' check(payment_status in ('입금 대기','입금 확인')),
  cooking_status text not null default '신규 주문' check(cooking_status in ('신규 주문','조리 중','조리 완료','서빙 완료'))
);
create table if not exists public.order_items (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  item_name text not null,
  quantity integer not null check(quantity > 0 and quantity <= 99),
  unit_price integer not null check(unit_price > 0),
  item_description text not null default '',
  served boolean not null default false
);
alter table public.order_items add column if not exists item_description text not null default '';
alter table public.order_items add column if not exists served boolean not null default false;
alter table public.orders add column if not exists special_drink_choice text not null default '';
create index if not exists orders_created_at_idx on public.orders(created_at desc);
create index if not exists orders_table_number_idx on public.orders(table_number);
create index if not exists order_items_order_id_idx on public.order_items(order_id);

alter table public.app_settings enable row level security;
alter table public.admin_users enable row level security;
alter table public.menu_inventory enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.admin_users where user_id = (select auth.uid()));
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

drop policy if exists "Public can read event settings" on public.app_settings;
create policy "Public can read event settings" on public.app_settings for select to anon, authenticated using (true);
drop policy if exists "Admins can change event settings" on public.app_settings;
create policy "Admins can change event settings" on public.app_settings for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Admins can read orders" on public.orders;
create policy "Admins can read orders" on public.orders for select to authenticated using (public.is_admin());
drop policy if exists "Admins can update orders" on public.orders;
create policy "Admins can update orders" on public.orders for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Admins can delete orders" on public.orders;
create policy "Admins can delete orders" on public.orders for delete to authenticated using (public.is_admin());
drop policy if exists "Admins can read order items" on public.order_items;
create policy "Admins can read order items" on public.order_items for select to authenticated using (public.is_admin());
drop policy if exists "Admins can update served items" on public.order_items;
create policy "Admins can update served items" on public.order_items for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Admins can read admin list" on public.admin_users;
create policy "Admins can read admin list" on public.admin_users for select to authenticated using (public.is_admin());
drop policy if exists "Anyone can read menu inventory" on public.menu_inventory;
drop policy if exists "Admins can read menu inventory" on public.menu_inventory;
create policy "Admins can read menu inventory" on public.menu_inventory for select to authenticated using (public.is_admin());

grant select on public.app_settings to anon, authenticated;
grant update on public.app_settings to authenticated;
grant select on public.orders, public.order_items to authenticated;
grant update(payment_status, cooking_status) on public.orders to authenticated;
grant delete on public.orders to authenticated;
grant update(served) on public.order_items to authenticated;
grant select on public.admin_users to authenticated;
revoke all on public.menu_inventory from anon, authenticated;
grant select on public.menu_inventory to authenticated;

create or replace function public.release_limited_set_stock_on_order_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_quantity integer;
begin
  select coalesce(sum(quantity),0)::integer into v_quantity
  from public.order_items
  where order_id=old.id and item_name='할로윈 ! special ! 세트';
  if v_quantity > 0 then
    update public.menu_inventory
    set quantity_sold=greatest(quantity_sold-v_quantity,0), updated_at=now()
    where item_name='할로윈 ! special ! 세트';
  end if;
  return old;
end;
$$;
revoke all on function public.release_limited_set_stock_on_order_delete() from public;
drop trigger if exists release_limited_set_stock_before_order_delete on public.orders;
create trigger release_limited_set_stock_before_order_delete
before delete on public.orders
for each row execute function public.release_limited_set_stock_on_order_delete();

drop function if exists public.get_halloween_special_remaining();
create or replace function public.is_halloween_special_available()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(bool_or(quantity_sold < quantity_limit), false)
  from public.menu_inventory
  where item_name = '할로윈 ! special ! 세트';
$$;
revoke all on function public.is_halloween_special_available() from public;
grant execute on function public.is_halloween_special_available() to anon, authenticated;

drop function if exists public.place_order(text,text,text,jsonb,text);
create or replace function public.place_order(
  p_table_number text,
  p_customer_name text,
  p_request_note text,
  p_items jsonb,
  p_access_token text,
  p_special_drink_choice text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prices jsonb := '{"할로윈 정식 세트":51000,"삼도천 단짠 세트":52000,"악마의 야식 세트":43000,"할로윈 ! special ! 세트":25000,"부대찌개":21000,"오뎅탕":19000,"공깃밥 / 면사리 추가":1000,"수육":24000,"지코바":23000,"더블순살치킨":22000,"훈제삼겹살":20000,"모둠감자튀김":15000,"두부김치":15000,"파인애플샤베트":9000,"콘치즈":9000,"맥주":5000,"매화수 / 청하":6000,"소주 (기타 술)":5000,"음료":2000,"라면밥 (지옥불 라면밥)":9000,"화채 (마녀의 눈알 화채)":14000}'::jsonb;
  v_descriptions jsonb := '{"할로윈 정식 세트":"부대찌개 · 수육 · 공깃밥/면사리 1개 · 에이드 1잔 (청포도·블루레몬·자몽 중 장바구니에서 선택)","삼도천 단짠 세트":"오뎅탕 · 마녀의 눈알 화채 · 훈제삼겹살","악마의 야식 세트":"지코바 · 모둠감자튀김 · 맥주","할로윈 ! special ! 세트":"지옥불 라면밥 · 마녀의 눈알 화채 · 에이드 1잔 (청포도·블루레몬·자몽 중 장바구니에서 선택)","공깃밥 / 면사리 추가":"공깃밥 또는 면사리 중 선택","라면밥 (지옥불 라면밥)":"지옥불 라면밥","화채 (마녀의 눈알 화채)":"마녀의 눈알 화채"}'::jsonb;
  v_total integer := 0;
  v_item jsonb;
  v_name text;
  v_qty integer;
  v_price integer;
  v_special_qty integer := 0;
  v_ade_qty integer := 0;
  v_order_id uuid;
  v_order_number text;
  v_hash text;
  v_order public.orders%rowtype;
  v_result jsonb;
begin
  if coalesce(trim(p_table_number),'') = '' then raise exception 'TABLE_REQUIRED'; end if;
  if p_access_token is null or length(p_access_token) < 20 then raise exception 'INVALID_TOKEN'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'EMPTY_ORDER'; end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'TOO_MANY_ITEMS'; end if;
  v_hash := encode(extensions.digest(p_access_token, 'sha256'), 'hex');
  select * into v_order from public.orders where access_token_hash = v_hash;
  if found then
    select coalesce(jsonb_agg(jsonb_build_object('name', item_name, 'quantity', quantity, 'unit_price', unit_price, 'description', item_description)), '[]'::jsonb)
      into v_result from public.order_items where order_id = v_order.id;
    return jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'created_at',v_order.created_at,'table_number',v_order.table_number,'customer_name',v_order.customer_name,'request_note',v_order.request_note,'special_drink_choice',v_order.special_drink_choice,'total_amount',v_order.total_amount,'payment_status',v_order.payment_status,'cooking_status',v_order.cooking_status,'items',v_result);
  end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_name := v_item->>'name';
    if not (v_prices ? v_name) then raise exception 'INVALID_MENU_ITEM'; end if;
    if (v_item->>'quantity') !~ '^[0-9]+$' then raise exception 'INVALID_QUANTITY'; end if;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 99 then raise exception 'INVALID_QUANTITY'; end if;
    v_price := (v_prices->>v_name)::integer;
    v_total := v_total + v_price * v_qty;
    if v_name = '할로윈 ! special ! 세트' then v_special_qty := v_special_qty + v_qty; end if;
    if v_name in ('할로윈 정식 세트','할로윈 ! special ! 세트') then v_ade_qty := v_ade_qty + v_qty; end if;
  end loop;
  if v_ade_qty > 0 and coalesce(trim(p_special_drink_choice),'') not in ('좀비 백신 에이드 (청포도)','드라큘라 수혈 에이드 (자몽)','블루문 에이드 (영혼 포션 · 블루레몬)') then
    raise exception 'SET_ADE_REQUIRED';
  end if;
  if v_special_qty > 0 then
    update public.menu_inventory
      set quantity_sold = quantity_sold + v_special_qty, updated_at = now()
      where item_name = '할로윈 ! special ! 세트'
        and quantity_sold + v_special_qty <= quantity_limit;
    if not found then raise exception 'HALLOWEEN_SPECIAL_SOLD_OUT'; end if;
  end if;
  v_order_number := 'P-' || to_char(now() at time zone 'Asia/Seoul','YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  insert into public.orders(order_number, access_token_hash, table_number, customer_name, request_note, special_drink_choice, total_amount)
    values(v_order_number,v_hash,trim(p_table_number),left(coalesce(trim(p_customer_name),''),30),left(coalesce(trim(p_request_note),''),300),coalesce(trim(p_special_drink_choice),''),v_total)
    returning id into v_order_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_name := v_item->>'name'; v_qty := (v_item->>'quantity')::integer; v_price := (v_prices->>v_name)::integer;
    insert into public.order_items(order_id,item_name,quantity,unit_price,item_description) values(v_order_id,v_name,v_qty,v_price,coalesce(v_descriptions->>v_name,''));
  end loop;
  select * into v_order from public.orders where id=v_order_id;
  select coalesce(jsonb_agg(jsonb_build_object('name', item_name, 'quantity', quantity, 'unit_price', unit_price, 'description', item_description)), '[]'::jsonb)
    into v_result from public.order_items where order_id = v_order_id;
  return jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'created_at',v_order.created_at,'table_number',v_order.table_number,'customer_name',v_order.customer_name,'request_note',v_order.request_note,'special_drink_choice',v_order.special_drink_choice,'total_amount',v_order.total_amount,'payment_status',v_order.payment_status,'cooking_status',v_order.cooking_status,'items',v_result);
end;
$$;

create or replace function public.get_order_by_token(p_access_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.orders%rowtype; v_items jsonb;
begin
  if p_access_token is null then return null; end if;
  select * into v_order from public.orders where access_token_hash=encode(extensions.digest(p_access_token,'sha256'),'hex');
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('name',item_name,'quantity',quantity,'unit_price',unit_price,'description',item_description)),'[]'::jsonb) into v_items from public.order_items where order_id=v_order.id;
  return jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'created_at',v_order.created_at,'table_number',v_order.table_number,'customer_name',v_order.customer_name,'request_note',v_order.request_note,'special_drink_choice',v_order.special_drink_choice,'total_amount',v_order.total_amount,'payment_status',v_order.payment_status,'cooking_status',v_order.cooking_status,'items',v_items);
end;
$$;
revoke all on function public.place_order(text,text,text,jsonb,text,text) from public;
revoke all on function public.get_order_by_token(text) from public;
grant execute on function public.place_order(text,text,text,jsonb,text,text) to anon, authenticated;
grant execute on function public.get_order_by_token(text) to anon, authenticated;

-- After creating a staff user in Authentication → Users, grant access with:
-- insert into public.admin_users(user_id) values ('AUTH_USER_UUID');
-- Never put a Supabase service-role/secret key in config.js or browser code.

-- Allow connected authorized staff browsers to receive live order/status changes.
do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='orders') then
      alter publication supabase_realtime add table public.orders;
    end if;
    if not exists (select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='order_items') then
      alter publication supabase_realtime add table public.order_items;
    end if;
    if not exists (select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='menu_inventory') then
      alter publication supabase_realtime add table public.menu_inventory;
    end if;
  end if;
end $$;
