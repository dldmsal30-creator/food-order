-- Reject new orders without a depositor name while preserving any older records.
do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint where conname='orders_customer_name_required' and conrelid='public.orders'::regclass) then
    alter table public.orders add constraint orders_customer_name_required check (length(trim(customer_name)) > 0) not valid;
  end if;
end $$;

-- 관리자 주문 편집 및 세트 구성별 제공 체크 저장 기능입니다.
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS served_components jsonb NOT NULL DEFAULT '{}'::jsonb;
create or replace function public.admin_update_order(
  p_order_id uuid,
  p_table_number text,
  p_items jsonb,
  p_special_drink_choice text default ''
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_prices jsonb := '{"할로윈 정식 세트":51000,"삼도천 단짠 세트":52000,"악마의 야식 세트":43000,"할로윈 ! special ! 세트":25000,"부대찌개":21000,"오뎅탕":19000,"공깃밥 / 면사리 추가":1000,"수육":24000,"지코바":23000,"더블순살치킨":22000,"훈제삼겹살":20000,"모둠감자튀김":15000,"두부김치":15000,"파인애플샤베트":9000,"콘치즈":9000,"맥주":5000,"매화수 / 청하":6000,"소주 (기타 술)":5000,"음료":2000,"라면밥 (지옥불 라면밥)":9000,"화채 (마녀의 눈알 화채)":14000}'::jsonb;
  v_descriptions jsonb := '{"할로윈 정식 세트":"부대찌개 · 수육 · 공깃밥/면사리 1개 · 에이드 1잔 (청포도·블루레몬·자몽 중 장바구니에서 선택)","삼도천 단짠 세트":"오뎅탕 · 마녀의 눈알 화채 · 훈제삼겹살","악마의 야식 세트":"지코바 · 모둠감자튀김 · 맥주","할로윈 ! special ! 세트":"지옥불 라면밥 · 마녀의 눈알 화채 · 에이드 1잔 (청포도·블루레몬·자몽 중 장바구니에서 선택)","공깃밥 / 면사리 추가":"공깃밥 또는 면사리 중 선택","라면밥 (지옥불 라면밥)":"지옥불 라면밥","화채 (마녀의 눈알 화채)":"마녀의 눈알 화채"}'::jsonb;
  v_item jsonb;
  v_name text;
  v_qty integer;
  v_price integer;
  v_total integer := 0;
  v_new_special integer := 0;
  v_old_special integer := 0;
  v_ade_qty integer := 0;
  v_old_items jsonb;
  v_served boolean;
  v_old_components jsonb;
  v_seen text[] := array[]::text[];
begin
  if not public.is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(trim(p_table_number),'') = '' then raise exception 'TABLE_REQUIRED'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'EMPTY_ORDER'; end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'TOO_MANY_ITEMS'; end if;
  perform 1 from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  select coalesce(jsonb_object_agg(item_name,jsonb_build_object('quantity',quantity,'served',served,'served_components',served_components)),'{}'::jsonb)
    into v_old_items from public.order_items where order_id=p_order_id;
  select coalesce(sum(quantity),0)::integer into v_old_special
    from public.order_items where order_id=p_order_id and item_name='할로윈 ! special ! 세트';
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_name := v_item->>'name';
    if not (v_prices ? v_name) then raise exception 'INVALID_MENU_ITEM'; end if;
    if v_name = any(v_seen) then raise exception 'DUPLICATE_MENU_ITEM'; end if;
    v_seen := array_append(v_seen,v_name);
    if (v_item->>'quantity') !~ '^[0-9]+$' then raise exception 'INVALID_QUANTITY'; end if;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 99 then raise exception 'INVALID_QUANTITY'; end if;
    v_price := (v_prices->>v_name)::integer;
    v_total := v_total + v_price * v_qty;
    if v_name = '할로윈 ! special ! 세트' then v_new_special := v_new_special + v_qty; end if;
    if v_name in ('할로윈 정식 세트','할로윈 ! special ! 세트') then v_ade_qty := v_ade_qty + v_qty; end if;
  end loop;
  if v_ade_qty > 0 and coalesce(trim(p_special_drink_choice),'') not in ('좀비 백신 에이드 (청포도)','드라큘라 수혈 에이드 (자몽)','블루문 에이드 (영혼 포션 · 블루레몬)') then
    raise exception 'SET_ADE_REQUIRED';
  end if;
  if v_new_special > v_old_special then
    update public.menu_inventory set quantity_sold=quantity_sold+(v_new_special-v_old_special),updated_at=now()
      where item_name='할로윈 ! special ! 세트' and quantity_sold+(v_new_special-v_old_special)<=quantity_limit;
    if not found then raise exception 'HALLOWEEN_SPECIAL_SOLD_OUT'; end if;
  elsif v_new_special < v_old_special then
    update public.menu_inventory set quantity_sold=greatest(quantity_sold-(v_old_special-v_new_special),0),updated_at=now()
      where item_name='할로윈 ! special ! 세트';
  end if;
  update public.orders set table_number=trim(p_table_number),total_amount=v_total,
    special_drink_choice=case when v_ade_qty>0 then trim(p_special_drink_choice) else '' end
    where id=p_order_id;
  delete from public.order_items where order_id=p_order_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_name := v_item->>'name';
    v_qty := (v_item->>'quantity')::integer;
    v_price := (v_prices->>v_name)::integer;
    v_served := coalesce((v_old_items->v_name->>'quantity')::integer=v_qty and coalesce((v_old_items->v_name->>'served')::boolean,false),false);
    v_old_components := case when (v_old_items->v_name->>'quantity')::integer=v_qty then coalesce(v_old_items->v_name->'served_components','{}'::jsonb) else '{}'::jsonb end;
    insert into public.order_items(order_id,item_name,quantity,unit_price,item_description,served,served_components)
      values(p_order_id,v_name,v_qty,v_price,coalesce(v_descriptions->>v_name,''),v_served,v_old_components);
  end loop;
end;
$$;
revoke all on function public.admin_update_order(uuid,text,jsonb,text) from public;
grant execute on function public.admin_update_order(uuid,text,jsonb,text) to authenticated;
create or replace function public.set_order_item_component_served(
  p_order_item_id bigint,
  p_component_key text,
  p_served boolean
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_item public.order_items%rowtype;
  v_parts text[];
  v_state jsonb;
  v_unit_text text;
  v_unit integer;
  v_component text;
  v_key text;
  v_part text;
  v_all_served boolean := true;
  v_colon integer;
begin
  if not public.is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if p_served is null then raise exception 'INVALID_SERVED_STATE'; end if;
  select * into v_item from public.order_items where id=p_order_item_id for update;
  if not found then raise exception 'ORDER_ITEM_NOT_FOUND'; end if;
  v_parts := case v_item.item_name
    when '할로윈 정식 세트' then array['부대찌개','수육','공깃밥 / 면사리 추가','에이드']
    when '삼도천 단짠 세트' then array['오뎅탕','화채 (마녀의 눈알 화채)','훈제삼겹살']
    when '악마의 야식 세트' then array['지코바','모둠감자튀김','맥주']
    when '할로윈 ! special ! 세트' then array['라면밥 (지옥불 라면밥)','화채 (마녀의 눈알 화채)','에이드']
    when '할로윈 특가 · 2인' then array['라면밥 (지옥불 라면밥)','화채 (마녀의 눈알 화채)','에이드']
    else null end;
  if v_parts is null then raise exception 'NOT_A_SET_MENU'; end if;
  v_colon := position(':' in coalesce(p_component_key,''));
  if v_colon < 2 then raise exception 'INVALID_COMPONENT_KEY'; end if;
  v_unit_text := left(p_component_key,v_colon-1);
  if v_unit_text !~ '^[0-9]+$' then raise exception 'INVALID_COMPONENT_KEY'; end if;
  v_unit := v_unit_text::integer;
  v_component := substring(p_component_key from v_colon+1);
  if v_unit < 0 or v_unit >= v_item.quantity or not (v_component = any(v_parts)) then raise exception 'INVALID_COMPONENT_KEY'; end if;
  v_state := coalesce(v_item.served_components,'{}'::jsonb);
  if v_item.served then
    for v_unit in 0..v_item.quantity-1 loop
      foreach v_part in array v_parts loop
        v_key := v_unit::text || ':' || v_part;
        if not (v_state ? v_key) then v_state := jsonb_set(v_state,array[v_key],'true'::jsonb,true); end if;
      end loop;
    end loop;
  end if;
  v_unit := v_unit_text::integer;
  v_state := jsonb_set(v_state,array[p_component_key],to_jsonb(p_served),true);
  for v_unit in 0..v_item.quantity-1 loop
    foreach v_part in array v_parts loop
      v_key := v_unit::text || ':' || v_part;
      if not coalesce((v_state->>v_key)::boolean,false) then v_all_served := false; end if;
    end loop;
  end loop;
  update public.order_items set served_components=v_state,served=v_all_served where id=p_order_item_id;
end;
$$;
revoke all on function public.set_order_item_component_served(bigint,text,boolean) from public;
grant execute on function public.set_order_item_component_served(bigint,text,boolean) to authenticated;
